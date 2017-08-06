module served.extension;

import core.exception;
import core.thread : Fiber;
import core.sync.mutex;

import std.algorithm;
import std.array;
import std.conv;
import std.datetime;
import fs = std.file;
import std.experimental.logger;
import std.functional;
import std.json;
import std.path;
import std.regex;
import io = std.stdio;
import std.string;

import served.ddoc;
import served.fibermanager;
import served.types;
import served.translate;

import workspaced.api;
import workspaced.coms;

bool hasDCD, hasDub, hasDscanner;

void require(alias val)()
{
	if (!val)
		throw new MethodException(ResponseError(ErrorCode.serverNotInitialized,
				val.stringof[3 .. $] ~ " isn't initialized yet"));
}

bool safe(alias fn, Args...)(Args args)
{
	try
	{
		fn(args);
		return true;
	}
	catch (Exception e)
	{
		error(e);
		return false;
	}
	catch (AssertError e)
	{
		error(e);
		return false;
	}
}

void changedConfig(string[] paths)
{
	foreach (path; paths)
	{
		switch (path)
		{
		case "d.stdlibPath":
			if (hasDCD)
				dcd.addImports(config.stdlibPath);
			break;
		case "d.projectImportPaths":
			if (hasDCD)
				dcd.addImports(config.d.projectImportPaths);
			break;
		case "d.dubConfiguration":
			if (hasDub)
			{
				auto configs = dub.configurations;
				if (configs.length == 0)
					rpc.window.showInformationMessage(translate!"d.ext.noConfigurations.project");
				else
				{
					auto defaultConfig = config.d.dubConfiguration;
					if (defaultConfig.length)
					{
						if (!configs.canFind(defaultConfig))
							rpc.window.showErrorMessage(
									translate!"d.ext.config.invalid.configuration"(defaultConfig));
						else
							dub.setConfiguration(defaultConfig);
					}
					else
						dub.setConfiguration(configs[0]);
				}
			}
			break;
		case "d.dubArchType":
			if (hasDub && config.d.dubArchType.length
					&& !dub.setArchType(JSONValue(config.d.dubArchType)))
				rpc.window.showErrorMessage(
						translate!"d.ext.config.invalid.archType"(config.d.dubArchType));
			break;
		case "d.dubBuildType":
			if (hasDub && config.d.dubBuildType.length
					&& !dub.setBuildType(JSONValue(config.d.dubBuildType)))
				rpc.window.showErrorMessage(
						translate!"d.ext.config.invalid.buildType"(config.d.dubBuildType));
			break;
		case "d.dubCompiler":
			if (hasDub && config.d.dubCompiler.length && !dub.setCompiler(config.d.dubCompiler))
				rpc.window.showErrorMessage(
						translate!"d.ext.config.invalid.compiler"(config.d.dubCompiler));
			break;
		default:
			break;
		}
	}
}

string[] getPossibleSourceRoots()
{
	import std.file;

	auto confPaths = config.d.projectImportPaths.map!(a => a.isAbsolute ? a
			: buildNormalizedPath(workspaceRoot, a));
	if (!confPaths.empty)
		return confPaths.array;
	auto a = buildNormalizedPath(workspaceRoot, "source");
	auto b = buildNormalizedPath(workspaceRoot, "src");
	if (exists(a))
		return [a];
	if (exists(b))
		return [b];
	return [workspaceRoot];
}

__gshared bool initialStart = true;
InitializeResult initialize(InitializeParams params)
{
	import std.file;

	trace("Initializing serve-d for " ~ params.rootPath);

	initialStart = true;
	crossThreadBroadcastCallback = &handleBroadcast;
	workspaceRoot = params.rootPath;
	chdir(workspaceRoot);
	trace("Starting dub...");
	bool disableDub = config.d.neverUseDub;
	if (!disableDub)
		hasDub = safe!(dub.startup)(workspaceRoot);
	if (!hasDub)
	{
		if (!disableDub)
			error("Failed starting dub - falling back to fsworkspace");
		rpc.window.showErrorMessage(translate!"d.ext.dubFail");
		try
		{
			fsworkspace.start(workspaceRoot, getPossibleSourceRoots);
		}
		catch (Exception e)
		{
			error(e);
			rpc.window.showErrorMessage(translate!"d.ext.fsworkspaceFail");
		}
	}
	InitializeResult result;
	result.capabilities.textDocumentSync = documents.syncKind;

	result.capabilities.completionProvider = CompletionOptions(false, [".", "("]);
	result.capabilities.signatureHelpProvider = SignatureHelpOptions(["(", ","]);
	result.capabilities.workspaceSymbolProvider = true;
	result.capabilities.definitionProvider = true;
	result.capabilities.hoverProvider = true;
	result.capabilities.codeActionProvider = true;

	result.capabilities.documentSymbolProvider = true;

	result.capabilities.documentFormattingProvider = true;

	trace("Starting dfmt");
	dfmt.start();
	trace("Starting dlangui");
	dlangui.start();
	trace("Starting importer");
	importer.start();
	trace("Starting moduleman");
	moduleman.start(workspaceRoot);

	result.capabilities.codeActionProvider = true;

	return result;
}

@protocolNotification("workspace/didChangeConfiguration")
void configNotify(DidChangeConfigurationParams params)
{
	if (!initialStart)
		return;
	initialStart = false;

	trace("Received configuration");
	startDCD();
	if (!hasDCD || dcd.isOutdated)
	{
		if (config.d.aggressiveUpdate)
			spawnFiber((&updateDCD).toDelegate);
		else
		{
			auto action = translate!"d.ext.compileProgram"("DCD");
			auto res = rpc.window.requestMessage(MessageType.error, translate!"d.served.failDCD"(workspaceRoot,
					config.d.dcdClientPath, config.d.dcdServerPath), [action]);
			if (res == action)
				spawnFiber((&updateDCD).toDelegate);
		}
	}

	startDScanner();
	if (!hasDscanner || dscanner.isOutdated)
	{
		if (config.d.aggressiveUpdate)
			spawnFiber((&updateDscanner).toDelegate);
		else
		{
			auto action = translate!"d.ext.compileProgram"("dscanner");
			auto res = rpc.window.requestMessage(MessageType.error,
					translate!"d.served.failDscanner"(workspaceRoot, config.d.dscannerPath), [action]);
			if (res == action)
				spawnFiber((&updateDscanner).toDelegate);
		}
	}
}

void handleBroadcast(JSONValue data)
{
	auto type = "type" in data;
	if (type && type.type == JSON_TYPE.STRING && type.str == "crash")
	{
		if (data["component"].str == "dcd")
			spawnFiber((&startDCD).toDelegate);
	}
}

void startDCD()
{
	hasDCD = safe!(dcd.start)(workspaceRoot, config.d.dcdClientPath,
			config.d.dcdServerPath, cast(ushort) 9166, false);
	if (hasDCD)
	{
		try
		{
			syncYield!(dcd.findAndSelectPort)(cast(ushort) 9166);
			dcd.startServer(config.stdlibPath);
			dcd.refreshImports();
		}
		catch (Exception e)
		{
			rpc.window.showErrorMessage(translate!"d.ext.dcdFail");
			error(e);
			hasDCD = false;
			return;
		}
		info("Imports: ", importPathProvider());
	}
}

void startDScanner()
{
	hasDscanner = safe!(dscanner.start)(workspaceRoot, config.d.dscannerPath);
}

string determineOutputFolder()
{
	import std.process : environment;

	version (linux)
	{
		if (fs.exists(buildPath(environment["HOME"], ".local", "share")))
			return buildPath(environment["HOME"], ".local", "share", "code-d", "bin");
		else
			return buildPath(environment["HOME"], ".code-d", "bin");
	}
	else version (Windows)
	{
		return buildPath(environment["APPDATA"], "code-d", "bin");
	}
	else
	{
		return buildPath(environment["HOME"], ".code-d", "bin");
	}
}

@protocolNotification("served/updateDscanner")
void updateDscanner()
{
	rpc.notifyMethod("coded/logInstall", "Installing dscanner");
	string outputFolder = determineOutputFolder;
	if (!fs.exists(outputFolder))
		fs.mkdirRecurse(outputFolder);
	version (Windows)
		auto buildCmd = ["cmd.exe", "/c", "build.bat"];
	else
		auto buildCmd = ["make"];
	bool success = compileDependency(outputFolder, "Dscanner", "https://github.com/Hackerpilot/Dscanner.git",
			[[config.git.path, "submodule", "update", "--init", "--recursive"], buildCmd]);
	if (success)
	{
		version (Windows)
			string finalDestination = buildPath(outputFolder, "Dscanner", "bin", "dscanner.exe");
		else
			string finalDestination = buildPath(outputFolder, "Dscanner", "bin", "dscanner");
		config.d.dscannerPath = finalDestination;
		rpc.notifyMethod("coded/updateSetting", UpdateSettingParams("dscannerPath",
				JSONValue(finalDestination), true));
		rpc.notifyMethod("coded/logInstall", "Successfully installed Dscanner");
		startDScanner();
	}
}

@protocolNotification("served/updateDCD")
void updateDCD()
{
	rpc.notifyMethod("coded/logInstall", "Installing DCD");
	string outputFolder = determineOutputFolder;
	if (!fs.exists(outputFolder))
		fs.mkdirRecurse(outputFolder);
	version (Windows)
		auto buildCmd = ["cmd.exe", "/c", "build.bat"];
	else
		auto buildCmd = ["make"];
	bool success = compileDependency(outputFolder, "DCD", "https://github.com/Hackerpilot/DCD.git",
			[[config.git.path, "submodule", "update", "--init", "--recursive"], buildCmd]);
	if (success)
	{
		string finalDestinationClient = buildPath(outputFolder, "DCD", "bin", "dcd-client");
		string finalDestinationServer = buildPath(outputFolder, "DCD", "bin", "dcd-server");
		version (Windows)
		{
			finalDestinationClient ~= ".exe";
			finalDestinationServer ~= ".exe";
		}
		config.d.dcdClientPath = finalDestinationClient;
		config.d.dcdServerPath = finalDestinationServer;
		rpc.notifyMethod("coded/updateSetting", UpdateSettingParams("dcdClientPath",
				JSONValue(finalDestinationClient), true));
		rpc.notifyMethod("coded/updateSetting", UpdateSettingParams("dcdServerPath",
				JSONValue(finalDestinationServer), true));
		rpc.notifyMethod("coded/logInstall", "Successfully installed DCD");
		startDCD();
	}
}

bool compileDependency(string cwd, string name, string gitURI, string[][] commands)
{
	import std.process;

	int run(string[] cmd, string cwd)
	{
		rpc.notifyMethod("coded/logInstall", "> " ~ cmd.join(" "));
		auto stdin = pipe();
		auto stdout = pipe();
		auto pid = spawnProcess(cmd, stdin.readEnd, stdout.writeEnd,
				stdout.writeEnd, null, Config.none, cwd);
		stdin.writeEnd.close();
		while (!pid.tryWait().terminated)
			Fiber.yield();
		foreach (line; stdout.readEnd.byLine)
			rpc.notifyMethod("coded/logInstall", line.idup);
		return pid.wait;
	}

	rpc.notifyMethod("coded/logInstall", "Installing into " ~ cwd);
	try
	{
		auto newCwd = buildPath(cwd, name);
		if (fs.exists(newCwd))
		{
			rpc.notifyMethod("coded/logInstall", "Deleting old installation from " ~ newCwd);
			fs.rmdirRecurse(newCwd);
		}
		auto ret = run([config.git.path, "clone", "--recursive", gitURI, name], cwd);
		if (ret != 0)
			throw new Exception("git ended with error code " ~ ret.to!string);
		foreach (command; commands)
			run(command, newCwd);
		return true;
	}
	catch (Exception e)
	{
		rpc.notifyMethod("coded/logInstall", "Failed to install " ~ name);
		rpc.notifyMethod("coded/logInstall", e.toString);
		return false;
	}
}

@protocolMethod("shutdown")
JSONValue shutdown()
{
	if (hasDub)
		dub.stop();
	if (hasDCD)
		dcd.stop();
	if (hasDscanner)
		dscanner.stop();
	dfmt.stop();
	dlangui.stop();
	importer.stop();
	moduleman.stop();
	return JSONValue(null);
}

CompletionItemKind convertFromDCDType(string type)
{
	switch (type)
	{
	case "c":
		return CompletionItemKind.class_;
	case "i":
		return CompletionItemKind.interface_;
	case "s":
	case "u":
		return CompletionItemKind.unit;
	case "a":
	case "A":
	case "v":
		return CompletionItemKind.variable;
	case "m":
	case "e":
		return CompletionItemKind.field;
	case "k":
		return CompletionItemKind.keyword;
	case "f":
		return CompletionItemKind.function_;
	case "g":
		return CompletionItemKind.enum_;
	case "P":
	case "M":
		return CompletionItemKind.module_;
	case "l":
		return CompletionItemKind.reference;
	case "t":
	case "T":
		return CompletionItemKind.property;
	default:
		return CompletionItemKind.text;
	}
}

SymbolKind convertFromDCDSearchType(string type)
{
	switch (type)
	{
	case "c":
		return SymbolKind.class_;
	case "i":
		return SymbolKind.interface_;
	case "s":
	case "u":
		return SymbolKind.package_;
	case "a":
	case "A":
	case "v":
		return SymbolKind.variable;
	case "m":
	case "e":
		return SymbolKind.field;
	case "f":
	case "l":
		return SymbolKind.function_;
	case "g":
		return SymbolKind.enum_;
	case "P":
	case "M":
		return SymbolKind.namespace;
	case "t":
	case "T":
		return SymbolKind.property;
	case "k":
	default:
		return cast(SymbolKind) 0;
	}
}

SymbolKind convertFromDscannerType(string type)
{
	switch (type)
	{
	case "g":
		return SymbolKind.enum_;
	case "e":
		return SymbolKind.field;
	case "v":
		return SymbolKind.variable;
	case "i":
		return SymbolKind.interface_;
	case "c":
		return SymbolKind.class_;
	case "s":
		return SymbolKind.class_;
	case "f":
		return SymbolKind.function_;
	case "u":
		return SymbolKind.class_;
	case "T":
		return SymbolKind.property;
	case "a":
		return SymbolKind.field;
	default:
		return cast(SymbolKind) 0;
	}
}

string substr(T)(string s, T start, T end)
{
	if (!s.length)
		return "";
	if (start < 0)
		start = 0;
	if (start >= s.length)
		start = s.length - 1;
	if (end > s.length)
		end = s.length;
	if (end < start)
		return s[start .. start];
	return s[start .. end];
}

string[] extractFunctionParameters(string sig, bool exact = false)
{
	if (!sig.length)
		return [];
	string[] params;
	ptrdiff_t i = sig.length - 1;

	if (sig[i] == ')' && !exact)
		i--;

	ptrdiff_t paramEnd = i + 1;

	void skipStr()
	{
		i--;
		if (sig[i + 1] == '\'')
			for (; i >= 0; i--)
				if (sig[i] == '\'')
					return;
		bool escapeNext = false;
		while (i >= 0)
		{
			if (sig[i] == '\\')
				escapeNext = false;
			if (escapeNext)
				break;
			if (sig[i] == '"')
				escapeNext = true;
			i--;
		}
	}

	void skip(char open, char close)
	{
		i--;
		int depth = 1;
		while (i >= 0 && depth > 0)
		{
			if (sig[i] == '"' || sig[i] == '\'')
				skipStr();
			else
			{
				if (sig[i] == close)
					depth++;
				else if (sig[i] == open)
					depth--;
				i--;
			}
		}
	}

	while (i >= 0)
	{
		switch (sig[i])
		{
		case ',':
			params ~= sig.substr(i + 1, paramEnd).strip;
			paramEnd = i;
			i--;
			break;
		case ';':
		case '(':
			auto param = sig.substr(i + 1, paramEnd).strip;
			if (param.length)
				params ~= param;
			reverse(params);
			return params;
		case ')':
			skip('(', ')');
			break;
		case '}':
			skip('{', '}');
			break;
		case ']':
			skip('[', ']');
			break;
		case '"':
		case '\'':
			skipStr();
			break;
		default:
			i--;
			break;
		}
	}
	reverse(params);
	return params;
}

unittest
{
	void assertEquals(A, B)(A a, B b)
	{
		assert(a == b,
				"\n\"" ~ a.to!string ~ "\"\nis expected to be\n\"" ~ b.to!string ~ "\", but wasn't!");
	}

	assertEquals(extractFunctionParameters("void foo()"), []);
	assertEquals(extractFunctionParameters(`auto bar(int foo, Button, my.Callback cb)`),
			["int foo", "Button", "my.Callback cb"]);
	assertEquals(extractFunctionParameters(`SomeType!(int, "int_") foo(T, Args...)(T a, T b, string[string] map, Other!"(" stuff1, SomeType!(double, ")double") myType, Other!"(" stuff, Other!")")`),
			["T a", "T b", "string[string] map", `Other!"(" stuff1`,
			`SomeType!(double, ")double") myType`, `Other!"(" stuff`, `Other!")"`]);
	assertEquals(extractFunctionParameters(`SomeType!(int,"int_")foo(T,Args...)(T a,T b,string[string] map,Other!"(" stuff1,SomeType!(double,")double")myType,Other!"(" stuff,Other!")")`),
			["T a", "T b", "string[string] map", `Other!"(" stuff1`,
			`SomeType!(double,")double")myType`, `Other!"(" stuff`, `Other!")"`]);
	assertEquals(extractFunctionParameters(`some_garbage(code); before(this); funcCall(4`,
			true), [`4`]);
	assertEquals(extractFunctionParameters(
			`some_garbage(code); before(this); funcCall(4, f(4)`, true), [`4`, `f(4)`]);
	assertEquals(extractFunctionParameters(`some_garbage(code); before(this); funcCall(4, ["a"], JSONValue(["b": JSONValue("c")]), recursive(func, call!s()), "texts )\"(too"`,
			true), [`4`, `["a"]`, `JSONValue(["b": JSONValue("c")])`,
			`recursive(func, call!s())`, `"texts )\"(too"`]);
}

// === Protocol Methods starting here ===

@protocolMethod("textDocument/completion")
CompletionList provideComplete(TextDocumentPositionParams params)
{
	auto document = documents[params.textDocument.uri];
	if (document.languageId != "d")
		return CompletionList.init;
	require!hasDCD;
	auto byteOff = cast(int) document.positionToBytes(params.position);
	JSONValue result;
	joinAll({ result = syncYield!(dcd.listCompletion)(document.text, byteOff); }, {

	});
	CompletionItem[] completion;
	switch (result["type"].str)
	{
	case "identifiers":
		foreach (identifier; result["identifiers"].array)
		{
			CompletionItem item;
			item.label = identifier["identifier"].str;
			item.kind = identifier["type"].str.convertFromDCDType;
			completion ~= item;
		}
		goto case;
	case "calltips":
		return CompletionList(false, completion);
	default:
		throw new Exception("Unexpected result from DCD");
	}
}

@protocolMethod("textDocument/signatureHelp")
SignatureHelp provideSignatureHelp(TextDocumentPositionParams params)
{
	auto document = documents[params.textDocument.uri];
	if (document.languageId != "d")
		return SignatureHelp.init;
	require!hasDCD;
	auto pos = cast(int) document.positionToBytes(params.position);
	auto result = syncYield!(dcd.listCompletion)(document.text, pos);
	SignatureInformation[] signatures;
	int[] paramsCounts;
	SignatureHelp help;
	switch (result["type"].str)
	{
	case "calltips":
		foreach (calltip; result["calltips"].array)
		{
			auto sig = SignatureInformation(calltip.str);
			auto funcParams = calltip.str.extractFunctionParameters;

			paramsCounts ~= cast(int) funcParams.length - 1;
			foreach (param; funcParams)
				sig.parameters ~= ParameterInformation(param);

			help.signatures ~= sig;
		}
		auto extractedParams = document.text[0 .. pos].extractFunctionParameters(true);
		help.activeParameter = max(0, cast(int) extractedParams.length - 1);
		size_t[] possibleFunctions;
		foreach (i, count; paramsCounts)
			if (count >= cast(int) extractedParams.length - 1)
				possibleFunctions ~= i;
		help.activeSignature = possibleFunctions.length ? cast(int) possibleFunctions[0] : 0;
		goto case;
	case "identifiers":
		return help;
	default:
		throw new Exception("Unexpected result from DCD");
	}
}

@protocolMethod("workspace/symbol")
SymbolInformation[] provideWorkspaceSymbols(WorkspaceSymbolParams params)
{
	import std.file;

	require!hasDCD;
	auto result = syncYield!(dcd.searchSymbol)(params.query);
	SymbolInformation[] infos;
	TextDocumentManager extraCache;
	foreach (symbol; result.array)
	{
		auto uri = uriFromFile(symbol["file"].str);
		auto doc = documents.tryGet(uri);
		Location location;
		if (!doc.uri)
			doc = extraCache.tryGet(uri);
		if (!doc.uri)
		{
			doc = Document(uri);
			try
			{
				doc.text = readText(symbol["file"].str);
			}
			catch (Exception e)
			{
				error(e);
			}
		}
		if (doc.text)
		{
			location = Location(doc.uri,
					TextRange(doc.bytesToPosition(cast(size_t) symbol["position"].integer)));
			infos ~= SymbolInformation(params.query,
					convertFromDCDSearchType(symbol["type"].str), location);
		}
	}
	return infos;
}

@protocolMethod("textDocument/documentSymbol")
SymbolInformation[] provideDocumentSymbols(DocumentSymbolParams params)
{
	auto document = documents[params.textDocument.uri];
	require!hasDscanner;
	auto result = syncYield!(dscanner.listDefinitions)(uriToFile(params.textDocument.uri),
			document.text);
	if (result.type == JSON_TYPE.NULL)
		return [];
	SymbolInformation[] ret;
	foreach (def; result.array)
	{
		SymbolInformation info;
		info.name = def["name"].str;
		info.location.uri = params.textDocument.uri;
		info.location.range = TextRange(Position(cast(uint) def["line"].integer - 1, 0));
		info.kind = convertFromDscannerType(def["type"].str);
		if (def["type"].str == "f" && def["name"].str == "this")
			info.kind = SymbolKind.constructor;
		const(JSONValue)* ptr;
		auto attribs = def["attributes"];
		if (null !is(ptr = "struct" in attribs) || null !is(ptr = "class" in attribs)
				|| null !is(ptr = "enum" in attribs) || null !is(ptr = "union" in attribs))
			info.containerName = (*ptr).str;
		ret ~= info;
	}
	return ret;
}

@protocolMethod("textDocument/definition")
ArrayOrSingle!Location provideDefinition(TextDocumentPositionParams params)
{
	auto document = documents[params.textDocument.uri];
	if (document.languageId != "d")
		return ArrayOrSingle!Location.init;
	require!hasDCD;
	auto result = syncYield!(dcd.findDeclaration)(document.text,
			cast(int) document.positionToBytes(params.position));
	if (result.type == JSON_TYPE.NULL)
		return ArrayOrSingle!Location.init;
	auto uri = document.uri;
	if (result[0].str != "stdin")
		uri = uriFromFile(result[0].str);
	size_t byteOffset = cast(size_t) result[1].integer;
	Position pos;
	auto found = documents.tryGet(uri);
	if (found.uri)
		pos = found.bytesToPosition(byteOffset);
	else
	{
		string abs = result[0].str;
		if (!abs.isAbsolute)
			abs = buildPath(workspaceRoot, abs);
		pos = Position.init;
		size_t totalLen;
		foreach (line; io.File(abs).byLine(io.KeepTerminator.yes))
		{
			totalLen += line.length;
			if (totalLen >= byteOffset)
				break;
			else
				pos.line++;
		}
	}
	return ArrayOrSingle!Location(Location(uri, TextRange(pos, pos)));
}

@protocolMethod("textDocument/formatting")
TextEdit[] provideFormatting(DocumentFormattingParams params)
{
	if (!config.d.enableFormatting)
		return [];
	auto document = documents[params.textDocument.uri];
	if (document.languageId != "d")
		return [];
	string[] args;
	if (config.d.overrideDfmtEditorconfig)
	{
		int maxLineLength = 120;
		int softMaxLineLength = 80;
		if (config.editor.rulers.length == 1)
		{
			maxLineLength = config.editor.rulers[0];
			softMaxLineLength = maxLineLength - 40;
		}
		else if (config.editor.rulers.length >= 2)
		{
			maxLineLength = config.editor.rulers[$ - 1];
			softMaxLineLength = config.editor.rulers[$ - 2];
		}
		//dfmt off
			args = [
				"--align_switch_statements", config.dfmt.alignSwitchStatements.to!string,
				"--brace_style", config.dfmt.braceStyle,
				"--end_of_line", document.eolAt(0).to!string,
				"--indent_size", params.options.tabSize.to!string,
				"--indent_style", params.options.insertSpaces ? "space" : "tab",
				"--max_line_length", maxLineLength.to!string,
				"--soft_max_line_length", softMaxLineLength.to!string,
				"--outdent_attributes", config.dfmt.outdentAttributes.to!string,
				"--space_after_cast", config.dfmt.spaceAfterCast.to!string,
				"--split_operator_at_line_end", config.dfmt.splitOperatorAtLineEnd.to!string,
				"--tab_width", params.options.tabSize.to!string,
				"--selective_import_space", config.dfmt.selectiveImportSpace.to!string,
				"--compact_labeled_statements", config.dfmt.compactLabeledStatements.to!string,
				"--template_constraint_style", config.dfmt.templateConstraintStyle
			];
			//dfmt on
	}
	auto result = syncYield!(dfmt.format)(document.text, args);
	return [TextEdit(TextRange(Position(0, 0),
			document.offsetToPosition(document.text.length)), result.str)];
}

@protocolMethod("textDocument/hover")
Hover provideHover(TextDocumentPositionParams params)
{
	auto document = documents[params.textDocument.uri];
	if (document.languageId != "d")
		return Hover.init;
	require!hasDCD;
	auto docs = syncYield!(dcd.getDocumentation)(document.text,
			cast(int) document.positionToBytes(params.position));
	Hover ret;
	if (docs.type == JSON_TYPE.ARRAY && docs.array.length)
		ret.contents = docs.array.map!(a => a.str.ddocToMarked).join();
	else if (docs.type == JSON_TYPE.STRING && docs.str.length)
		ret.contents = docs.str.ddocToMarked;
	return ret;
}

private auto importRegex = regex(`import ([a-zA-Z_]\w*(?:\.[a-zA-Z_]\w*)*)?`);
private auto undefinedIdentifier = regex(
		`^undefined identifier '(\w+)'(?:, did you mean .*? '(\w+)'\?)?$`);
private auto undefinedTemplate = regex(`template '(\w+)' is not defined`);
private auto noProperty = regex(`^no property '(\w+)'(?: for type '.*?')?$`);
private auto moduleRegex = regex(`module\s+([a-zA-Z_]\w*\s*(?:\s*\.\s*[a-zA-Z_]\w*)*)\s*;`);
private auto whitespace = regex(`\s*`);

@protocolMethod("textDocument/codeAction")
Command[] provideCodeActions(CodeActionParams params)
{
	auto document = documents[params.textDocument.uri];
	if (document.languageId != "d")
		return [];
	Command[] ret;
	foreach (diagnostic; params.context.diagnostics)
	{
		auto match = diagnostic.message.matchFirst(importRegex);
		if (diagnostic.message.canFind("import "))
		{
			if (!match)
				continue;
			return [Command("Import " ~ match[1], "code-d.addImport",
					[JSONValue(match[1]), JSONValue(document.positionToOffset(params.range[0]))])];
		}
		else if (cast(bool)(match = diagnostic.message.matchFirst(undefinedIdentifier))
				|| cast(bool)(match = diagnostic.message.matchFirst(undefinedTemplate))
				|| cast(bool)(match = diagnostic.message.matchFirst(noProperty)))
		{
			string[] files;
			joinAll({
				if (hasDscanner)
					files ~= syncYield!(dscanner.findSymbol)(match[1]).array.map!"a[`file`].str".array;
			}, {
				if (hasDCD)
					files ~= syncYield!(dcd.searchSymbol)(match[1]).array.map!"a[`file`].str".array;
			});
			string[] modules;
			foreach (file; files.sort().uniq)
			{
				if (!isAbsolute(file))
					file = buildNormalizedPath(workspaceRoot, file);
				int lineNo = 0;
				foreach (line; io.File(file).byLine)
				{
					if (++lineNo >= 100)
						break;
					auto match2 = line.matchFirst(moduleRegex);
					if (match2)
					{
						modules ~= match2[1].replaceAll(whitespace, "").idup;
						break;
					}
				}
			}
			foreach (mod; modules.sort().uniq)
				ret ~= Command("Import " ~ mod, "code-d.addImport", [JSONValue(mod),
						JSONValue(document.positionToOffset(params.range[0]))]);
		}
	}
	return ret;
}

@protocolMethod("served/listConfigurations")
string[] listConfigurations()
{
	require!hasDub;
	return dub.configurations;
}

@protocolMethod("served/switchConfig")
bool switchConfig(string value)
{
	require!hasDub;
	return dub.setConfiguration(value);
}

@protocolMethod("served/getConfig")
string getConfig(string value)
{
	require!hasDub;
	return dub.configuration;
}

@protocolMethod("served/listArchTypes")
string[] listArchTypes()
{
	require!hasDub;
	return dub.archTypes;
}

@protocolMethod("served/switchArchType")
bool switchArchType(string value)
{
	require!hasDub;
	return dub.setArchType(JSONValue(["arch-type" : JSONValue(value)]));
}

@protocolMethod("served/getArchType")
string getArchType(string value)
{
	require!hasDub;
	return dub.archType;
}

@protocolMethod("served/listBuildTypes")
string[] listBuildTypes()
{
	require!hasDub;
	return dub.buildTypes;
}

@protocolMethod("served/switchBuildType")
bool switchBuildType(string value)
{
	require!hasDub;
	return dub.setBuildType(JSONValue(["build-type" : JSONValue(value)]));
}

@protocolMethod("served/getBuildType")
string getBuildType()
{
	require!hasDub;
	return dub.buildType;
}

@protocolMethod("served/getCompiler")
string getCompiler()
{
	require!hasDub;
	return dub.compiler;
}

@protocolMethod("served/switchCompiler")
bool switchCompiler(string value)
{
	require!hasDub;
	return dub.setCompiler(value);
}

@protocolMethod("served/addImport")
auto addImport(AddImportParams params)
{
	auto document = documents[params.textDocument.uri];
	return importer.add(params.name.idup, document.text, params.location, params.insertOutermost);
}

@protocolMethod("served/restartServer")
bool restartServer()
{
	require!hasDCD;
	syncYield!(dcd.restartServer);
	return true;
}

@protocolMethod("served/updateImports")
bool updateImports()
{
	bool success;
	if (hasDub)
		success = syncYield!(dub.update).type == JSON_TYPE.TRUE;
	require!hasDCD;
	dcd.refreshImports();
	return success;
}

// === Protocol Notifications starting here ===

struct FileOpenInfo
{
	SysTime at;
}

__gshared FileOpenInfo[string] freshlyOpened;

@protocolNotification("workspace/didChangeWatchedFiles")
void onChangeFiles(DidChangeWatchedFilesParams params)
{
	info(params);

	foreach (change; params.changes)
	{
		string file = change.uri;
		if (change.type == FileChangeType.created && file.endsWith(".d"))
		{
			auto document = documents[file];
			auto isNew = file in freshlyOpened;
			info(file);
			if (isNew)
			{
				// Only edit if creation & opening is < 800msecs apart (vscode automatically opens on creation),
				// we don't want to affect creation from/in other programs/editors.
				if (Clock.currTime - isNew.at > 800.msecs)
				{
					freshlyOpened.remove(file);
					continue;
				}
				// Sending applyEdit so it is undoable
				auto patches = moduleman.normalizeModules(file.uriToFile, document.text);
				if (patches.length)
				{
					WorkspaceEdit edit;
					edit.changes[file] = patches.map!(a => TextEdit(TextRange(document.bytesToPosition(a.range[0]),
							document.bytesToPosition(a.range[1])), a.content)).array;
					rpc.sendMethod("workspace/applyEdit", ApplyWorkspaceEditParams(edit));
				}
			}
		}
	}
}

@protocolNotification("textDocument/didOpen")
void onDidOpenDocument(DidOpenTextDocumentParams params)
{
	freshlyOpened[params.textDocument.uri] = FileOpenInfo(Clock.currTime);

	info(freshlyOpened);
}

int changeTimeout;
@protocolNotification("textDocument/didChange")
void onDidChangeDocument(DocumentLinkParams params)
{
	auto document = documents[params.textDocument.uri];
	if (document.languageId != "d")
		return;
	int delay = document.text.length > 50 * 1024 ? 1000 : 200; // be slower after 50KiB
	if (hasDscanner)
	{
		clearTimeout(changeTimeout);
		changeTimeout = setTimeout({
			import served.linters.dscanner;

			lint(document);
			// Delay to avoid too many requests
		}, delay);
	}
}

@protocolNotification("textDocument/didSave")
void onDidSaveDocument(DidSaveTextDocumentParams params)
{
	auto document = documents[params.textDocument.uri];
	auto fileName = params.textDocument.uri.uriToFile.baseName;

	if (document.languageId == "d" || document.languageId == "diet")
	{
		if (!config.d.enableLinting)
			return;
		joinAll({
			if (hasDscanner && config.d.enableStaticLinting)
			{
				if (document.languageId == "diet")
					return;
				import served.linters.dscanner;

				lint(document);
			}
		}, {
			if (hasDub && config.d.enableDubLinting)
			{
				import served.linters.dub;

				lint(document);
			}
		});
	}
	else if (fileName == "dub.json" || fileName == "dub.sdl")
	{
		info("Updating dependencies");
		rpc.window.runOrMessage(dub.upgrade(), MessageType.warning, translate!"d.ext.dubUpgradeFail");
		rpc.window.runOrMessage(dub.updateImportPaths(true), MessageType.warning,
				translate!"d.ext.dubImportFail");
	}
}

@protocolNotification("served/killServer")
void killServer()
{
	dcd.killServer();
}

struct Timeout
{
	StopWatch sw;
	int msTimeout;
	void delegate() callback;
	int id;
}

int setTimeout(void delegate() callback, int ms)
{
	trace("Setting timeout for ", ms, " ms");
	Timeout to;
	to.msTimeout = ms;
	to.callback = callback;
	to.sw.start();
	to.id = ++timeoutID;
	synchronized (timeoutsMutex)
		timeouts ~= to;
	return to.id;
}

void setImmediate(void delegate() callback)
{
	setTimeout(callback, 0);
}

int setTimeout(void delegate() callback, Duration timeout)
{
	return setTimeout(callback, cast(int) timeout.total!"msecs");
}

void clearTimeout(int id)
{
	synchronized (timeoutsMutex)
		foreach_reverse (i, ref timeout; timeouts)
		{
			if (timeout.id == id)
			{
				timeout.sw.stop();
				if (timeouts.length > 1)
					timeouts[i] = timeouts[$ - 1];
				timeouts.length--;
				return;
			}
		}
}

__gshared void delegate(void delegate()) spawnFiber;

shared static this()
{
	spawnFiber = (&setImmediate).toDelegate;
}

__gshared int timeoutID;
__gshared Timeout[] timeouts;
__gshared Mutex timeoutsMutex;

// Called at most 100x per second
void parallelMain()
{
	timeoutsMutex = new Mutex;
	while (true)
	{
		synchronized (timeoutsMutex)
			foreach_reverse (i, ref timeout; timeouts)
			{
				if (timeout.sw.peek.msecs >= timeout.msTimeout)
				{
					timeout.sw.stop();
					timeout.callback();
					trace("Calling timeout");
					if (timeouts.length > 1)
						timeouts[i] = timeouts[$ - 1];
					timeouts.length--;
				}
			}
		Fiber.yield();
	}
}
