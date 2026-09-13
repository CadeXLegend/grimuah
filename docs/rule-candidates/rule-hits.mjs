#!/usr/bin/env node
// print the rows one detector produces over the research corpus, so a native port
// can be compared site by site against `grimuah check`
//
// usage   node docs/rule-candidates/rule-hits.mjs <rule-name>          relPath:line
//         VERBOSE=1 ... relPath:line plus the snippet the detector built
//
// it walks the whole corpus and hands the same array to every `detect` call. a
// detector that maps a declared name to its declared return type caches that map
// on corpus identity, so a harness that passes no corpus never builds the map and
// throws on the first call site. passing the corpus costs a detector that ignores
// it nothing, which is why one script serves both shapes
//
// the corpus is a separate checkout, so it is the one path that cannot be derived:
// GRIMUAH_RESEARCH_CORPUS overrides it, the way the research harness does
//
// a rule's port is proven by comparing both sides through the same `sort`, because
// the rows come out in corpus order here and in report order from grimuah, and the
// shell's `sort` collates differently from any sort this script could do (a dot is
// ignorable to glibc, so `sleep.service.ts` sorts after `sleepover.service.ts`):
//
//   node docs/rule-candidates/rule-hits.mjs <rule> > /tmp/candidate.txt
//   cd ~/dev/sleepy && grimuah check 2>&1 >/dev/null \
//     | grep "<the rule's message>" | cut -d: -f1,2 > /tmp/live.txt
//   sort -o /tmp/candidate.txt /tmp/candidate.txt
//   sort -o /tmp/live.txt /tmp/live.txt
//   diff /tmp/candidate.txt /tmp/live.txt

import { readdir, readFile } from "node:fs/promises";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import ts from "typescript";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const CANDIDATE_DIR = join(ROOT, "docs", "rule-candidates", "candidates");
const CORPUS_ROOT = process.env.GRIMUAH_RESEARCH_CORPUS ?? "/home/cade/dev/sleepy";
const CORPUS_ROOTS = ["src", "lib", "gateway"];

const walk = async (dir, out = []) => {
  const entries = await readdir(dir, { withFileTypes: true });
  for (const entry of entries) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name === "node_modules" || entry.name === ".git") continue;
      await walk(full, out);
    } else if (entry.name.endsWith(".ts")) {
      out.push(full);
    }
  }
  return out;
};

const ruleName = process.argv[2];
if (ruleName === undefined) {
  console.error("usage: node docs/rule-candidates/rule-hits.mjs <rule-name>");
  process.exit(1);
}
const detector = (await import(join(CANDIDATE_DIR, `${ruleName}.mjs`))).default;

const filePaths = [];
for (const corpusRoot of CORPUS_ROOTS) {
  await walk(join(CORPUS_ROOT, corpusRoot), filePaths);
}

const corpus = [];
for (const filePath of filePaths) {
  const text = await readFile(filePath, "utf8");
  corpus.push({
    // `filePath` is the absolute path a detector that looks the project's own
    // config up needs, and `relPath` is the one the rows are keyed by
    filePath,
    relPath: relative(CORPUS_ROOT, filePath),
    text,
    sourceFile: ts.createSourceFile(filePath, text, ts.ScriptTarget.Latest, true),
  });
}

let hits = 0;
const filesWithHits = new Set();
for (const entry of corpus) {
  const found = detector.detect({
    ts,
    sourceFile: entry.sourceFile,
    filePath: entry.filePath,
    relPath: entry.relPath,
    text: entry.text,
    corpus,
  });
  for (const hit of found) {
    hits += 1;
    filesWithHits.add(entry.relPath);
    console.log(`${entry.relPath}:${hit.line}${process.env.VERBOSE ? ` ${hit.snippet}` : ""}`);
  }
}
console.error(`${ruleName}: ${hits} hits across ${filesWithHits.size} files (of ${corpus.length} files)`);
