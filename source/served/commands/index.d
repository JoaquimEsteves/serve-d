module served.commands.index;

import std.datetime;
import std.experimental.logger;

import workspaced.api;
import workspaced.coms;

import served.lsp.protocol;
import served.lsp.protoext;
import served.lsp.textdocumentmanager;
import served.lsp.uri;
import served.types;
import served.utils.async;

void backgroundIndex()
{
	setImmediate({
		reindexAll();
	});
}

@protocolNotification("served/reindexAll")
void reindexAll()
{
	import std.algorithm : map;
	import std.datetime.stopwatch;

	foreach (workspace; workspaces)
	{
		if (!workspace.config.d.enableIndex)
			continue;
		auto stdlib = workspace.stdlibPath;
		auto folderPath = workspace.folder.uri.uriToFile;
		if (backend.has!IndexComponent(folderPath))
		{
			auto indexer = backend.get!IndexComponent(folderPath);
			auto sources = indexer.getIndexSources(stdlib);

			StopWatch sw;
			sw.start();

			trace("Indexing ", sources.length, " files inside workspace ", indexer.cwd, "...");
			joinAll(sources.map!(s => () {
				indexer.reindexFromDisk(s);
			}));
			trace("Done indexing ", sources.length, " files in ", sw.peek);
			indexer.saveIndex();
		}
	}

	auto now = Clock.currTime;

	foreach (ref doc; documents.documentStore)
	{
		if (doc.getLanguageId != "d")
			continue;
		if (!workspace(doc.uri, false).config.d.enableIndex)
			continue;

		auto filePath = doc.uri.uriToFile;
		if (backend.hasBest!IndexComponent(filePath))
		{
			auto indexer = backend.best!IndexComponent(filePath);
			indexer.reindex(filePath, now, doc.rawText.length, doc.rawText, true);
		}
	}

	foreach (workspace; workspaces)
	{
		if (!workspace.config.d.enableIndex)
			continue;
		auto folderPath = workspace.folder.uri.uriToFile;
		if (backend.has!IndexComponent(folderPath))
		{
			auto indexer = backend.get!IndexComponent(folderPath);
			traceIndexerStats(indexer);

			delayedSaveIndex(indexer);
		}
	}
}

TimerID reindexChangeTimeout;
@protocolNotification("textDocument/didChange")
void reindexOnChange(DidChangeTextDocumentParams params)
{
	auto document = documents[params.textDocument.uri];
	if (document.getLanguageId != "d")
		return;
	if (!workspace(params.textDocument.uri).config.d.enableIndex)
		return;

	int delay = document.length > 50 * 1024 ? 500 : 50; // be slower after 50KiB
	clearTimeout(reindexChangeTimeout);
	reindexChangeTimeout = setTimeout({
		auto filePath = params.textDocument.uri.uriToFile;
		if (backend.hasBest!IndexComponent(filePath))
		{
			auto now = Clock.currTime;
			document = documents[params.textDocument.uri];
			auto indexer = backend.best!IndexComponent(filePath);
			indexer.reindex(filePath, now, document.rawText.length, document.rawText, false);
			delayedSaveIndex(indexer);
		}
	}, delay);
}

@protocolNotification("textDocument/didSave")
void reindexOnSave(DidSaveTextDocumentParams params)
{
	auto document = documents[params.textDocument.uri];
	if (document.getLanguageId != "d")
		return;
	if (!workspace(params.textDocument.uri).config.d.enableIndex)
		return;

	auto filePath = params.textDocument.uri.uriToFile;
	clearTimeout(reindexChangeTimeout);

	if (backend.hasBest!IndexComponent(filePath))
	{
		auto indexer = backend.best!IndexComponent(filePath);
		indexer.reindexSaved(filePath, document.rawText);
		delayedSaveIndex(indexer);
	}
}

TimerID reindexSaveTimeout;
private void delayedSaveIndex(IndexComponent index)
{
	clearTimeout(reindexSaveTimeout);
	reindexSaveTimeout = setTimeout({
		index.saveIndex();
	}, 2_500);
}

private void traceIndexerStats(IndexComponent index)
{
	import core.memory;
	GC.collect();
	GC.minimize();

	trace("Indexer stats for ", index.refInstance.cwd, ":");
	auto stats = index.getHealth();
	trace("- failed files: ", stats.failedFiles);
	trace("- total modules: ", stats.indexedModules);
	trace("- total definitions: ", stats.numDefinitions);
	trace("- total imports: ", stats.numImports);
}
