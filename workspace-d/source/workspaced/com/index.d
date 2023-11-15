module workspaced.com.index;

// version = TraceCache;
// version = BenchmarkLocalCachedIndexing;

import dparse.ast;
import dparse.lexer;
import dparse.parser;
import dparse.rollback_allocator;

import core.sync.mutex;
import std.algorithm;
import std.array;
import std.container.rbtree;
import std.conv;
import std.datetime.stopwatch;
import std.datetime.systime;
import std.experimental.logger : info, trace, warning;
import std.file;
import std.range;
import std.typecons;

import workspaced.api;
import workspaced.helpers;

import workspaced.com.dscanner;
import workspaced.com.moduleman;

import workspaced.index_format;

public import workspaced.index_format : ModuleRef;

@component("index")
@instancedOnly
class IndexComponent : ComponentWrapper
{
	mixin DefaultComponentWrapper;

	protected void load()
	{
		if (!refInstance)
			throw new Exception("index.reindex requires to be instanced");

		if (!fileIndex)
		{
			trace("Loading file index from ", IndexCache.defaultFilename);
			StopWatch sw;
			sw.start();
			fileIndex = IndexCache.load();
			trace("loaded file index with ", fileIndex.indexCount, " entries in ", sw.peek);
		}

		allGlobals.initialize();
		cachesMutex = new Mutex();
		config.stringBehavior = StringBehavior.source;
	}

	ModuleRef reindexFromDisk(string file)
	{
		import std.file : readText;

		try
		{
			if (auto cache = fileIndex.getIfActive(file))
			{
				auto modName = cache.modName;
				forceReindexFromCache(
					file,
					cache.lastModified,
					cache.fileSize,
					cache.modName,
					cache.moduleDefinition);
				return modName;
			}
			else
			{
				auto meta = IndexCache.getFileMeta(file);
				if (meta is typeof(meta).init)
					throw new Exception("Failed to read file metadata");
				auto content = readText(file);
				return reindex(meta.expand, content, true);
			}
		}
		catch (Exception e)
		{
			trace("Index error in ", file, ": ", e);

			throw e;
		}
	}

	ModuleRef reindexSaved(string file, scope const(char)[] code)
	{
		auto meta = IndexCache.getFileMeta(file);
		if (meta is typeof(meta).init)
			throw new Exception("Cannot read file metadata from " ~ file);
		return reindex(meta.expand, code, true);
	}

	ModuleRef reindex(string file, SysTime lastWrite, ulong fileSize, scope const(char)[] code, bool force)
	{
		auto mod = get!ModulemanComponent.moduleName(code);

		if (mod is null)
		{
			if (!force)
				return null;

			ImportCacheEntry entry;
			entry.success = false;
			entry.fileName = file;

			synchronized (cachesMutex)
			{
				cache.require(mod, ImportCacheEntry(true, file)).replaceFrom(mod, entry, this);
			}
			return mod;
		}
		else
		{
			auto entry = generateCacheEntry(file, lastWrite, fileSize, code);
			if (entry == ImportCacheEntry.init && !force)
				return null;

			synchronized (cachesMutex)
			{
				cache
					.require(mod, ImportCacheEntry(true, file, lastWrite, fileSize))
					.replaceFrom(mod, entry, this);
			}

			return mod;
		}
	}

	private void forceReindexFromCache(string file, SysTime lastWrite, ulong fileSize, const ModuleRef mod, const ModuleDefinition cache)
	{
		synchronized (cachesMutex)
		{
			auto storeCacheEntry = &this.cache
				.require(mod, ImportCacheEntry(true, file, SysTime.init, 0));

			if (cast()storeCacheEntry.fileName == file
				&& cast()storeCacheEntry.lastModified == lastWrite
				&& cast()storeCacheEntry.fileSize == fileSize
				&& cast()storeCacheEntry._definitions.length == cache.definitions.length)
				return;

			ModuleDefinition duped;
			duped.hasMixin = cache.hasMixin;
			duped.definitions = new DefinitionElement[cache.definitions.length];
			foreach (i; 0 .. duped.length)
				duped.definitions[i] = cache.definitions[i].dup;

			auto entry = generateCacheEntry(file, lastWrite, fileSize, duped);
			this.cache[mod].replaceFrom(mod, entry, this);
		}
	}

	void saveIndex()
	{
		synchronized (cachesMutex)
		{
			foreach (mod, ref entry; cache)
				if (entry.success)
				{
					auto hasMixin = entry.isIncomplete;
					fileIndex.setFile(
						entry.fileName,
						cast()entry.lastModified,
						entry.fileSize,
						mod,
						cast(DefinitionElement[])entry._definitions,
						hasMixin);
				}
			fileIndex.save();
		}
		trace("Saved file index with ", fileIndex.indexCount, " entries to ", fileIndex.fileName);
	}

	void iterateAll(scope void delegate(const ModuleRef mod, string fileName, scope const ref DefinitionElement definition) cb)
	{
		synchronized (cachesMutex)
		{
			foreach (mod, ref entry; cache)
			{
				if (!entry.success)
					continue;

				foreach (scope ref d; entry._definitions)
					cb(mod, entry.fileName, cast()d);
			}
		}
	}

	void iterateDefinitions(ModuleRef mod, scope void delegate(scope const DefinitionElement definition) cb)
	{
		synchronized (cachesMutex)
		{
			if (auto v = mod in cache)
			{
				if (!v.success)
					return;

				foreach (scope ref d; v._definitions)
					cb(cast()d);
			}
		}
	}

	void iterateSymbolsStartingWith(string s, scope void delegate(string symbol, char type, scope const ModuleRef fromModule) cb)
	{
		iterateGlobalsStartingWith(s, (scope item) {
			cb(item.name, item.type, item.fromModule);
		});
	}

	void iterateModuleReferences(ModuleRef mod, scope void delegate(ModuleRef definition) cb)
	{
		synchronized (cachesMutex)
		{
			if (auto v = mod in reverseImports)
				foreach (subMod; *v)
					cb(subMod);
		}
	}

	void iteratePublicImports(ModuleRef mod, scope void delegate(ModuleRef definition) cb)
	{
		synchronized (cachesMutex)
		{
			if (auto v = mod in cache)
			{
				if (!v.success)
					return;

				foreach (scope ref i; v._allImports)
					if (!i.insideAggregate && !i.insideFunction && i.visibility.isPublicImportVisibility)
						cb(cast()i.name);
			}
		}
	}

	void iteratePublicImportsRecursive(ModuleRef startMod, scope void delegate(ModuleRef parent, ModuleRef definition) cb)
	{
		synchronized (cachesMutex)
		{
			bool[ModuleRef] visited;
			ModuleRef[] stack = [startMod];
			while (stack.length)
			{
				auto mod = stack[$ - 1];
				stack.length--;
				if (mod in visited)
					continue;
				visited[mod] = true;
				if (auto v = mod in cache)
				{
					if (!v.success)
						return;

					foreach (scope ref i; v._allImports)
					{
						if (!i.insideAggregate && !i.insideFunction && i.visibility.isPublicImportVisibility)
						{
							cb(mod, cast()i.name);
							stack.assumeSafeAppend ~= cast()i.name;
						}
					}
				}
			}
		}
	}

	void iterateIncompleteModules(scope void delegate(ModuleRef definition) cb)
	{
		synchronized (cachesMutex)
		{
			foreach (mod, ref entry; cache)
			{
				if (entry.success && entry.isIncomplete)
					cb(mod);
			}
		}
	}

	void dropIndex(ModuleRef key)
	{
		synchronized (cachesMutex)
		{
			if (auto entry = key in cache)
			{
				ImportCacheEntry cleared;
				entry.replaceFrom(key, cleared, this);
				cache.remove(key);
			}
		}
	}

	string getIndexedFileName(ModuleRef forModule)
	{
		synchronized (cachesMutex)
		{
			if (auto entry = forModule in cache)
				return entry.fileName;
		}
		return null;
	}

	string[] getIndexSources(string[] stdlib)
	{
		auto files = appender!(string[]);
		foreach (path; stdlib)
			appendSourceFiles(files, path);
		foreach (path; importPaths())
			appendSourceFiles(files, path);
		foreach (file; importFiles())
			if (existsAndIsFile(file))
				files ~= file;
		return files.data;
	}

	IndexHealthReport getHealth()
	{
		IndexHealthReport ret;
		synchronized (cachesMutex)
		{
			foreach (key, ref entry; cache)
			{
				if (entry.success)
				{
					ret.indexedModules++;
					ret.numDefinitions += entry._definitions.length;
					ret.numImports += entry._allImports.length;
				}
				else
				{
					ret.failedFiles ~= entry.fileName;
				}
			}
		}
		return ret;
	}

	string[][string] dumpReverseImports()
	{
		synchronized (cachesMutex)
		{
			string[][string] ret;
			foreach (key, value; reverseImports)
				ret[key] = value.array;
			return ret;
		}
	}

private:
	__gshared LexerConfig config;

	static struct InterestingGlobal
	{
		string name;
		ModuleRef fromModule;
		char type;

		this(ref const DefinitionElement def, ModuleRef sourceModule)
		{
			name = def.name;
			type = def.type;
			fromModule = sourceModule;
		}

		int opCmp(ref const InterestingGlobal other) const
		{
			if (name < other.name)
				return -1;
			if (name > other.name)
				return 1;
			if (fromModule < other.fromModule)
				return -1;
			if (fromModule > other.fromModule)
				return 1;
			return 0;
		}

		bool opEquals(const InterestingGlobal other) const
		{
			return name == other.name && fromModule == other.fromModule;
		}
	}

	import std.experimental.allocator.gc_allocator;

	__gshared Mutex cachesMutex;
	__gshared ImportCacheEntry[ModuleRef] cache;

	__gshared RedBlackTree!ModuleRef[ModuleRef] reverseImports;
	__gshared RedBlackTree!ModuleRef[string] reverseDefinitions;
	__gshared OrderedKeyedList!InterestingGlobal allGlobals;

	version (unittest) void clearAll()
	{
		synchronized (cachesMutex)
		{
			cache = null;
			reverseImports = null;
			reverseDefinitions = null;
			allGlobals.clear();
			// fileIndex = IndexCache.load();
		}
	}

	void iterateGlobalsStartingWith(string s, scope void delegate(scope InterestingGlobal g) item)
	{
		if (!isInterestingGlobalName(s))
			return;

		synchronized (cachesMutex)
		{
			if (s.length == 0)
			{
				foreach (arr; allGlobals.allBuckets)
					foreach (ref g; arr)
						item(g);
			}
			else if (s.length == 1)
			{
				InterestingGlobal q;
				q.name = s;
				foreach (ref g; allGlobals.bucket(q))
					item(g);
			}
			else
			{
				InterestingGlobal q;
				q.name = s;
				auto bucket = allGlobals.bucket(q);
				auto i = assumeSorted(bucket).lowerBound(q).length;
				while (i < bucket.length && bucket.ptr[i].name.startsWith(s))
				{
					item(bucket.ptr[i]);
					i++;
				}
			}
		}
	}

	void _addedImport(ref const DefinitionElement modElem, ModuleRef sourceModule)
	{
		auto mod = modElem.name;
		auto ptr = &reverseImports.require(mod, new RedBlackTree!ModuleRef);
		ptr.insert(sourceModule);
		// insertSet(*ptr, sourceModule, 32);
	}

	void _removedImport(ref const DefinitionElement modElem, ModuleRef sourceModule)
	{
		auto mod = modElem.name;
		if (auto ptr = mod in reverseImports)
			ptr.removeKey(sourceModule);
			// removeSet(*ptr, sourceModule);
	}

	void _addedDefinition(ref const DefinitionElement def, ModuleRef sourceModule)
	{
		auto ptr = &reverseDefinitions.require(def.name, new RedBlackTree!ModuleRef);
		ptr.insert(sourceModule);
		// insertSet(*ptr, sourceModule, 64);
		if (isInterestingGlobal(def))
			allGlobals.insert(InterestingGlobal(def, sourceModule));
	}

	void _removedDefinition(ref const DefinitionElement def, ModuleRef sourceModule)
	{
		if (auto ptr = def.name in reverseDefinitions)
			ptr.removeKey(sourceModule);
			// removeSet(*ptr, sourceModule);
		if (isInterestingGlobal(def))
			allGlobals.remove(InterestingGlobal(def, sourceModule));
	}

	static bool isInterestingGlobal(ref const DefinitionElement def)
	{
		return def.isImportable && def.visibility.isVisibleOutside
			&& isInterestingGlobalName(def.name);
	}

	static bool isInterestingGlobalName(string name)
	{
		return name.length > 1 && name[0] != '_' && name != "this"
			&& isValidDIdentifier(name);
	}

	static __gshared IndexCache fileIndex;

	ImportCacheEntry generateCacheEntry(string file, SysTime writeTime, ulong fileSize, scope const(char)[] code)
	{
		scope tokens = getTokensForParser(cast(ubyte[]) code, config, &workspaced.stringCache);
		if (!tokens.length)
			return ImportCacheEntry.init;

		auto modDef = get!DscannerComponent.listDefinitions(file, code, true,
			ExtraMask.nullOnError | ExtraMask.imports | ExtraMask.includeFunctionMembers);
		modDef.definitions.sort!"a.cmpTypeAndName(b) < 0";
		return generateCacheEntry(file, writeTime, fileSize, modDef);
	}

	ImportCacheEntry generateCacheEntry(string file, SysTime writeTime, ulong fileSize, ModuleDefinition elems)
	{
		ImportCacheEntry result;
		result.fileName = file;
		result.lastModified = writeTime;
		result.fileSize = fileSize;
		result.success = true;
		result.isIncomplete = elems.hasMixin;
		result._definitions = elems.definitions;
		return result;
	}
}

struct ImportCacheEntry
{
	bool success;
	string fileName;
	SysTime lastModified;
	ulong fileSize;
	bool isIncomplete;

	private DefinitionElement[] _allImports;
	private DefinitionElement[] _definitions;

	@disable this(this);

	private void replaceFrom(ModuleRef thisModule, ref ImportCacheEntry other, IndexComponent index)
	{
		other.generateImports();

		success = other.success;
		fileName = other.fileName;
		cast()lastModified = cast()other.lastModified;
		fileSize = other.fileSize;
		isIncomplete = other.isIncomplete;

		synchronized (index.cachesMutex)
		{
			auto newImports = move(other._allImports);
			auto newDefinitions = move(other._definitions);
			newImports.diffInto!("a.cmpTypeAndName(b) < 0", DefinitionElement, ModuleRef)(
				(cast()this)._allImports, &index._addedImport, &index._removedImport,
				thisModule);
			newDefinitions.diffInto!("a.cmpTypeAndName(b) < 0", DefinitionElement, ModuleRef)(
				(cast()this)._definitions, &index._addedDefinition, &index._removedDefinition,
				thisModule);
		}
	}

	private void generateImports()
	{
		_allImports = null;
		size_t start = -1;
		foreach (i, ref def; _definitions)
		{
			if (def.type == 'I')
			{
				if (start == -1)
					start = i;
			}
			else if (start != -1)
			{
				_allImports = _definitions[start .. i];
				return;
			}
		}

		if (start != -1)
			_allImports = _definitions[start .. $];
	}
}

private void diffInto(alias less = "a<b", T, Args...)(T[] from, ref T[] into,
	scope void delegate(ref T, Args) onAdded, scope void delegate(ref T, Args) onRemoved,
	Args extraArgs)
{
	import std.functional : binaryFun;

	size_t lhs, rhs;
	while (lhs < from.length && rhs < into.length)
	{
		if (binaryFun!less(from.ptr[lhs], into.ptr[rhs]))
		{
			onAdded(from.ptr[lhs], extraArgs);
			lhs++;
		}
		else if (binaryFun!less(into.ptr[rhs], from.ptr[lhs]))
		{
			onRemoved(into.ptr[rhs], extraArgs);
			rhs++;
		}
		else
		{
			lhs++;
			rhs++;
		}
	}

	if (lhs < from.length)
		foreach (ref a; from.ptr[lhs .. from.length])
			onAdded(a, extraArgs);
	if (rhs < into.length)
		foreach (ref a; into.ptr[rhs .. into.length])
			onRemoved(a, extraArgs);

	move(from, into);
}

/// Returns: [added, removed]
private T[][2] diffInto(alias less = "a<b", T)(scope return T[] from, ref scope return T[] into)
{
	T[] added, removed;
	diffInto!(less, T, typeof(null))(from, into, (ref v, _) { added ~= v; }, (ref v, _) { removed ~= v; }, null);
	return [added, removed];
}

unittest
{
	int[] result = [1];

	int[] a = [1, 2, 3];
	int[] b = [2, 3, 5];
	int[] c = [2, 3, 5, 5];
	int[] d = [2, 3, 4, 5, 5];
	int[] e = [1, 3, 5];
	int[] f = [];

	assert(a.diffInto(result) == [[2, 3], []]);
	assert(result == [1, 2, 3]);

	assert(b.diffInto(result) == [[5], [1]]);
	assert(result == [2, 3, 5]);

	assert(c.diffInto(result) == [[5], []]);
	assert(result == [2, 3, 5, 5]);

	assert(d.diffInto(result) == [[4], []]);
	assert(result == [2, 3, 4, 5, 5]);

	assert(e.diffInto(result) == [[1], [2, 4, 5]]);
	assert(result == [1, 3, 5]);

	assert(f.diffInto(result) == [[], [1, 3, 5]]);
	assert(result == []);
}

struct IndexHealthReport
{
	size_t indexedModules;
	size_t numImports;
	size_t numDefinitions;
	string[] failedFiles;
}

private void appendSourceFiles(R)(ref R range, string path)
{
	import std.file : exists, dirEntries, SpanMode;
	import std.path : extension;

	try
	{
		if (!existsAndIsDir(path))
			return;

		foreach (file; dirEntries(path, SpanMode.breadth))
		{
			if (!file.isFile)
				continue;
			if (file.extension == ".d" || file.extension == ".D")
				range ~= file;
		}
	}
	catch (Exception e)
	{
	}
}

private void insertSet(alias less = "a<b", T)(ref T[] arr, T item, int initialReserve)
{
	import std.functional : binaryFun;

	if (arr.length == 0)
	{
		arr.reserve(initialReserve);
		arr ~= move(item);
	}
	else
	{
		insertSortedNoDup!less(arr, move(item));
	}
}

private void removeSet(alias less = "a<b", T)(ref T[] arr, const auto ref T item)
{
	if (arr.length == 0)
		return;
	else if (arr.length == 1)
	{
		if (arr.ptr[0] == item)
		{
			arr.length = 0;
			arr = arr.assumeSafeAppend;
		}
	}
	else
	{
		auto i = assumeSorted!less(arr).lowerBound(item).length;
		if (i != arr.length && arr.ptr[i] == item)
		{
			arr = arr.remove(i);
			arr = arr.assumeSafeAppend;
		}
	}
}

bool isStdLib(const ModuleRef mod)
{
	return mod.startsWith("std.", "core.", "etc.") || mod == "object";
}

string getModuleSortKey(const ModuleRef mod)
{
	if (mod.startsWith("std."))
		return "1_";
	else if (mod.startsWith("core.", "etc."))
		return "2_";
	else
		return "3_";
}

struct OrderedKeyedList(T, alias key = "a.name")
{
	import std.functional;

	// 0-9 = '0'-'9'
	// 10-35 = 'A'-'Z'
	// 36 = '_'
	// 37-62 = 'a'-'z'
	// 63 = other
	T[][10 + 26 * 2 + 2] allBuckets;
	// RedBlackTree!T[10 + 26 * 2 + 2] allBuckets;
	// RedBlackTree!T allBuckets;

	void initialize()
	{
		// allBuckets = new RedBlackTree!T;
		// foreach (ref v; allBuckets)
		// 	v = new RedBlackTree!T;
	}

	ref auto bucket(const ref T item)
	{
		auto name = unaryFun!key(item);
		assert(name.length);
		char key = name[0];
		if (key >= '0' && key <= '9')
			return allBuckets[key - '0'];
		else if (key >= 'A' && key <= 'Z')
			return allBuckets[key - 'A' + 10];
		else if (key == '_')
			return allBuckets[36];
		else if (key >= 'a' && key <= 'z')
			return allBuckets[key - 'a' + 37];
		else
			return allBuckets[63];
	}

	void clear()
	{
		// allBuckets.clear();
		foreach (v; allBuckets)
		{
			// v.clear();
			v.length = 0;
		}
	}

	void insert(T item)
	{
		// allBuckets.insert(item);
		insertSet(bucket(item), item, 4096);
		// bucket(item).insert(item);
	}

	void remove(T item)
	{
		// allBuckets.removeKey(item);
		removeSet(bucket(item), item);
		// bucket(item).removeKey(item);
	}

	size_t totalCount() const @property
	{
		return allBuckets[].map!"a.length".sum;
		// return allBuckets.length;
	}
}

version (BenchmarkLocalCachedIndexing)
version (none) // TODO: autoIndexSources replaced with getIndexSources + running all tasks as caller & saving if needed (second argument)
unittest
{
	import std.stdio;
	import std.experimental.logger;

	globalLogLevel = LogLevel.trace;

	static if (__VERSION__ < 2101)
		sharedLog = new FileLogger(stderr);
	else
		sharedLog = (() @trusted => cast(shared) new FileLogger(stderr))();

	scope backend = new WorkspaceD();
	auto workspace = makeTemporaryTestingWorkspace;
	auto instance = backend.addInstance(workspace.directory);
	backend.register!IndexComponent;
	backend.register!DscannerComponent;
	backend.register!ModulemanComponent;
	IndexComponent index = instance.get!IndexComponent;
	StopWatch sw;

	foreach (i; 0 .. 11)
	{
		index.clearAll();
		if (i != 0)
			sw.start();
		index.autoIndexSources([
			"/usr/include/dlang/dmd"
		], i == 0);
		if (i != 0)
			sw.stop();
		writeln("all globals: ", index.allGlobals.totalCount);
		if (i == 0)
		{
			import core.thread;
			Thread.sleep(1.seconds);
		}
	}
	writeln("Total indexing time: ", sw.peek);
}
