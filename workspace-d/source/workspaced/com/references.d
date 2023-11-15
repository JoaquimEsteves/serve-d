module workspaced.com.references;

import workspaced.api;
import workspaced.helpers;

import workspaced.com.dcd;
import workspaced.com.index;
import workspaced.com.moduleman;

import std.file;
import std.experimental.logger;

@component("references")
@instancedOnly
class ReferencesComponent : ComponentWrapper
{
	mixin DefaultComponentWrapper;

	protected void load()
	{
		if (!refInstance)
			throw new Exception("references component requires to be instanced");
	}

	/// Basic text-search-based references lookup.
	References findReferences(string file, scope const(char)[] code, int pos,
		void delegate(References) asyncFoundPart)
	{
		auto decl = get!DCDComponent.findDeclaration(code, pos);
		References ret;

		if (decl is DCDDeclaration.init)
			return References.init;

		if (decl.file == "stdin")
			decl.file = file;

		ret.definitionFile = decl.file;
		ret.definitionLocation = cast(int)decl.position;

		scope definitionCode = readText(decl.file);
		string identifier = getIdentifierAt(definitionCode, decl.position).idup;
		string startModule = get!ModulemanComponent.moduleName(definitionCode);

		auto localUse = get!DCDComponent.findLocalUse(
			definitionCode, ret.definitionLocation);

		if (localUse.declarationFilePath == "stdin")
			localUse.declarationFilePath = ret.definitionFile;

		foreach (use; localUse.uses)
			ret.references ~= References.Reference(
				localUse.declarationFilePath, cast(int)use);

		asyncFoundPart(ret);

		if (identifier.length)
		{
			bool[ModuleRef] visited;
			visited[startModule] = true;
			grepRecursive(ret,
				startModule,
				identifier,
				visited,
				asyncFoundPart);
			grepIncomplete(ret,
				identifier,
				visited,
				asyncFoundPart);
		}

		return ret;
	}

private:
	void grepRecursive(ref References ret, ModuleRef start, string identifier,
		ref bool[ModuleRef] visited, void delegate(References) asyncFoundPart)
	{
		ModuleRef[] stack = [start];
		stack.reserve(32);
		while (stack.length)
		{
			auto item = stack[$ - 1];
			stack.length--;

			get!IndexComponent.iterateModuleReferences(item, (other) {
				if (other in visited)
					return;
				visited[other] = true;

				auto filename = get!IndexComponent.getIndexedFileName(other);
				if (filename.length)
				{
					scope content = readText(filename);
					auto slice = grepFileReferences(ret, content, filename, identifier);
					asyncFoundPart(References(null, 0, slice));
				}
				else
				{
					warningf("Failed to find source for module '%s' for find references. (from imports usage)", other);
				}

				stack.assumeSafeAppend ~= other;
			});
			get!IndexComponent.iteratePublicImports(item, (other) {
				if (other in visited)
					return;
				visited[other] = true;

				auto filename = get!IndexComponent.getIndexedFileName(other);
				if (filename.length)
				{
					scope content = readText(filename);
					auto slice = grepFileReferences(ret, content, filename, identifier);
					asyncFoundPart(References(null, 0, slice));
				}
				else
				{
					warningf("Failed to find source for module '%s' for find references. (from public imports usage)", other);
				}

				stack.assumeSafeAppend ~= other;
			});
		}
	}

	void grepIncomplete(ref References ret, string identifier,
		ref bool[ModuleRef] visited, void delegate(References) asyncFoundPart)
	{
		get!IndexComponent.iterateIncompleteModules((other) {
			if (other in visited)
				return;
			visited[other] = true;
			// ignore incomplete stdlib, hacky but improves performance for now
			if (isStdLib(other))
				return;

			auto filename = get!IndexComponent.getIndexedFileName(other);
			if (filename.length)
			{
				scope content = readText(filename);
				auto slice = grepFileReferences(ret, content, filename, identifier);
				asyncFoundPart(References(null, 0, slice));
			}
			else
			{
				warningf("Failed to find source for module '%s' for find references. (from incomplete/mixin files)", other);
			}

			grepRecursive(ret, other, identifier, visited, asyncFoundPart);
		});
	}

	static References.Reference[] grepFileReferences(ref References ret, scope const(char)[] code, string file, string identifier)
	{
		ptrdiff_t i = 0;
		size_t start = ret.references.length;
		while (true)
		{
			i = indexOfKeyword(code, identifier, i);
			if (i == -1)
				break;
			ret.references ~= References.Reference(file, cast(int)i);
			i++;
		}
		return ret.references[start .. $];
	}
}

struct References
{
	struct Reference
	{
		string file;
		int location;
	}

	string definitionFile;
	int definitionLocation;
	Reference[] references;
}
