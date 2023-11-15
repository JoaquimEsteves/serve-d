import Compiler = std.compiler;
import std.file;
import std.json;
import std.path;
import std.stdio;
import std.string;
import std.traits;

import workspaced.api;
import workspaced.coms;

WorkspaceD backend;

void main(string[] args)
{
	import std.experimental.logger;

	globalLogLevel = LogLevel.trace;

	static if (__VERSION__ < 2101)
		sharedLog = new FileLogger(stderr);
	else
		sharedLog = (() @trusted => cast(shared) new FileLogger(stderr))();

	string dir = buildNormalizedPath(getcwd, "..", "tc_fsworkspace");
	backend = new WorkspaceD();
	backend.register!DubComponent;
	scope (exit)
		backend.shutdown();

	if (args.length > 1)
	{
		foreach (folder; args[1 .. $])
			if (!tryDub(folder, false))
				throw new Exception("Failed " ~ folder);

		stderr.writeln("All inputs passed!");
	}
	else
	{
		assert(tryDub("valid"));
		assert(!tryDub("empty1"));
		assert(!tryDub("empty2"));
		assert(tryDub("empty3"));
		assert(!tryDub("invalid"));
		assert(tryDub("sourcelib"));
		version (Windows)
			assert(tryDub("empty_windows"));
		assert(tryDub("missing_dep"));
		stderr.writeln("Success!");
	}
}

bool tryDub(string path, bool clean = true)
{
	DubComponent dub;
	try
	{
		if (clean)
		{
			if (exists(buildNormalizedPath(getcwd, path, ".dub")))
				rmdirRecurse(buildNormalizedPath(getcwd, path, ".dub"));
			if (exists(buildNormalizedPath(getcwd, path, "dub.selections.json")))
				remove(buildNormalizedPath(getcwd, path, "dub.selections.json"));
		}

		auto dir = buildNormalizedPath(getcwd, path);
		backend.addInstance(dir);
		dub = backend.get!DubComponent(dir);
	}
	catch (Exception e)
	{
		stderr.writeln(path, ": ", e.msg);
		return false;
	}

	auto tryRun(string fn, Args...)(string trace, Args args)
	{
		try
		{
			static if (is(typeof(mixin("dub." ~ fn ~ "(args)")) == void))
			{
				mixin("dub." ~ fn ~ "(args);");
				stderr.writeln(trace, ": pass ", fn);
				return;
			}
			else
			{
				auto ret = mixin("dub." ~ fn ~ "(args)");
				stderr.writeln(trace, ": pass ", fn, " = ", ret);
				return ret;
			}
		}
		catch (Exception e)
		{
			stderr.writeln(trace, ": failed to run ", fn, ": ", e.msg);
			static if (!is(typeof(return) == void))
				return typeof(return).init;
		}
		catch (Error e)
		{
			stderr.writeln(trace, ": assert error in ", fn, ": ", e.msg);
			throw e;
		}
	}

	foreach (step; 0 .. clean ? 2 : 1)
	{
		stderr.writeln("step #", step + 1, ": ", path);
		tryRun!"isValidConfiguration"(path);
		if (clean)
			tryRun!"upgradeAndSelectAll"(path);
		else
			tryRun!"selectAndDownloadMissing"(path);
		tryRun!"isValidConfiguration"(path);
		tryRun!"dependencies"(path);
		tryRun!"rootDependencies"(path);
		tryRun!"imports"(path);
		tryRun!"stringImports"(path);
		tryRun!"fileImports"(path);
		tryRun!"configurations"(path);
		tryRun!"buildTypes"(path);
		tryRun!"configuration"(path);
		tryRun!"setConfiguration"(path, dub.configuration);
		tryRun!"archTypes"(path);
		tryRun!"archType"(path);
		tryRun!"setArchType"(path, "x86");
		tryRun!"buildType"(path);
		tryRun!"setBuildType"(path, "debug");
		tryRun!"compiler"(path);
		static if (Compiler.vendor == Compiler.Vendor.gnu)
			tryRun!"setCompiler"(path, "gdc");
		else static if (Compiler.vendor == Compiler.Vendor.llvm)
			tryRun!"setCompiler"(path, "ldc2");
		else
			tryRun!"setCompiler"(path, "dmd");
		tryRun!"name"(path);
		tryRun!"path"(path);
		tryRun!"build"(path);
		// restart
		tryRun!"update"(path);
	}

	return true;
}
