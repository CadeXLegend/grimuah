#!/usr/bin/env node
// research harness for grimuah rule candidates
//
// loads every detector in docs/rule-candidates/candidates/, runs it over the sleepy corpus
// and the grimuah examples holdout, applies the quality gates below and
// prints METRIC lines. gates are frozen after the baseline run -- changing
// them changes the metric and must be logged as an experiment
//
// gate summary
//   actionable   title, rationale >= 30, replacement >= 10, known enums
//   signal       >= 3 hits across >= 2 distinct files (recurrence, not a one-off)
//   novelty      patternKey disjoint from the shipped rule set, and < 60% of
//                hit locations already covered by a shipped-rule detector
//   generality   detector source contains no sleepy domain vocabulary token
//   distinct     < 70% hit-location overlap with an already-accepted candidate

import { readdir, readFile, writeFile } from "node:fs/promises";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join, relative, basename, sep } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import ts from "typescript";

// ROOT is the grimuah checkout, derived from this file so the harness cannot be
// run from the wrong directory
const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
// the corpus is a separate checkout, so it is the one path that cannot be relative
const CORPUS_ROOT =
  process.env.GRIMUAH_RESEARCH_CORPUS ?? "/home/cade/dev/sleepy";
const CORPUS_ROOTS = ["src", "lib", "gateway"];
const HOLDOUT_ROOT = join(ROOT, "examples");
const CANDIDATE_DIR = join(ROOT, "docs", "rule-candidates", "candidates");
const REJECTED_DIR = join(ROOT, "docs", "rule-candidates", "rejected");
// the hand-authored guide, never written by the harness while AUTO_CATALOGUE_ONLY holds
const CATALOGUE = join(ROOT, "docs", "rule-candidates", "catalogue.md");
const LOCAL_CATALOGUE = join(ROOT, "docs", "rule-candidates", "evidence.md");
const AUTO_CATALOGUE_ONLY = true;

const MIN_HITS = 3;
const MIN_FILES = 2;
const MAX_EXISTING_OVERLAP = 0.6;
const MAX_CANDIDATE_OVERLAP = 0.7;
const MIN_RATIONALE = 30;
const MIN_REPLACEMENT = 10;
const MIN_DOMAIN_TOKEN = 4;
// precision guard: a detector that flags a large share of the corpus is almost
// always matching something broader than the rule it claims to be
const MAX_HITS = 300;
const MAX_FILE_SHARE = 0.6;

const CATEGORIES = new Set([
  "types",
  "sql",
  "declarative",
  "complexity",
  "resilience",
  "performance",
  "patterns",
  "architecture",
]);
const LAYERS = new Set(["cosmetic", "structural", "resilience", "behavioural"]);
const TIERS = new Set(["grit", "prepass"]);
const SEVERITIES = new Set(["error", "warn"]);

// shipped grimuah rules -- pattern keys a candidate must not re-implement
const EXISTING_PATTERN_KEYS = new Set([
  "em-dash",
  "file-suffix",
  "centralized-dir",
  "import-firewall",
  "innate-depth",
  "singleton",
  "switch",
  "c-style-for",
  "double-eq",
  "let",
  "null-literal",
  "as-any",
  "chained-cast",
  "proxy-reexport",
  "const-as-const-enum",
  "throw",
  "bare-catch",
  "silent-catch",
  "bound-catch",
]);

const GENERIC_TOKENS = new Set([
  "types",
  "type",
  "config",
  "spec",
  "specs",
  "service",
  "services",
  "repo",
  "repos",
  "command",
  "commands",
  "callbacks",
  "handler",
  "handlers",
  "middleware",
  "component",
  "components",
  "task",
  "tasks",
  "util",
  "utils",
  "index",
  "schema",
  "interaction",
  "response",
  "outcome",
  "pattern",
  "patterns",
  "regex",
  "assets",
  "module",
  "declaration",
  "bridge",
  "smoke",
  "market", // 'market-price' is infra, not a rule-domain word
  // batch 26: a compiler API term a rule about type members cannot avoid writing, since
  // PropertySignature, MethodSignature and CallSignature are the nodes it must match
  "signature",
]);

const lineOf = (sourceFile, node) =>
  sourceFile.getLineAndCharacterOfPosition(node.getStart(sourceFile)).line + 1;

const collapse = (input) => input.replace(/\s+/g, " ").trim();

// ---- corpus loading ---------------------------------------------------

const walk = async (dir, predicate) => {
  if (!existsSync(dir)) return [];
  const entries = await readdir(dir, { withFileTypes: true });
  const nested = await Promise.all(
    entries.map(async (entry) => {
      const full = join(dir, entry.name);
      if (entry.isDirectory()) {
        if (entry.name === "node_modules" || entry.name.startsWith("."))
          return [];
        return walk(full, predicate);
      }
      return predicate(full) ? [full] : [];
    }),
  );
  return nested.flat();
};

const loadCorpus = async (roots) => {
  const files = (
    await Promise.all(
      roots.map((root) =>
        walk(join(CORPUS_ROOT, root), (f) => f.endsWith(".ts")),
      ),
    )
  ).flat();
  return Promise.all(
    files.map(async (filePath) => {
      const text = await readFile(filePath, "utf8");
      return {
        filePath,
        relPath: relative(CORPUS_ROOT, filePath),
        text,
        lines: text.split("\n"),
        sourceFile: ts.createSourceFile(
          filePath,
          text,
          ts.ScriptTarget.Latest,
          true,
        ),
      };
    }),
  );
};

const loadHoldout = async () => {
  if (!existsSync(HOLDOUT_ROOT)) return [];
  const files = await walk(HOLDOUT_ROOT, (f) => f.endsWith(".ts"));
  return Promise.all(
    files.map(async (filePath) => {
      const text = await readFile(filePath, "utf8");
      return {
        filePath,
        relPath: relative(HOLDOUT_ROOT, filePath),
        text,
        lines: text.split("\n"),
        sourceFile: ts.createSourceFile(
          filePath,
          text,
          ts.ScriptTarget.Latest,
          true,
        ),
      };
    }),
  );
};

// domain vocabulary derived from sleepy file names -- a detector mentioning
// any of these is matching on this project's subject matter, not on a general
// structural pattern
const deriveDomainTokens = (corpus) => {
  const tokens = new Set();
  for (const file of corpus) {
    const name = basename(file.filePath).replace(/\.(ts|d\.ts)$/, "");
    for (const token of name.split(/[-.]/)) {
      const lower = token.toLowerCase();
      if (lower.length >= MIN_DOMAIN_TOKEN && !GENERIC_TOKENS.has(lower)) {
        tokens.add(lower);
      }
    }
  }
  return tokens;
};

// ---- shipped-rule detectors (novelty check) --------------------------

const findNodes = (sourceFile, predicate) => {
  const hits = [];
  const visit = (node) => {
    if (predicate(node)) hits.push(node);
    ts.forEachChild(node, visit);
  };
  visit(sourceFile);
  return hits;
};

const SHIPPED_DETECTORS = {
  let: (sourceFile) =>
    findNodes(
      sourceFile,
      (node) =>
        ts.isVariableDeclarationList(node) &&
        (node.flags & ts.NodeFlags.Let) !== 0,
    ),
  "double-eq": (sourceFile) =>
    findNodes(
      sourceFile,
      (node) =>
        ts.isBinaryExpression(node) &&
        (node.operatorToken.kind === ts.SyntaxKind.EqualsEqualsToken ||
          node.operatorToken.kind === ts.SyntaxKind.ExclamationEqualsToken),
    ),
  throw: (sourceFile) =>
    findNodes(sourceFile, (node) => ts.isThrowStatement(node)),
  "null-literal": (sourceFile) =>
    findNodes(sourceFile, (node) => node.kind === ts.SyntaxKind.NullKeyword),
  "as-any": (sourceFile) =>
    findNodes(
      sourceFile,
      (node) =>
        ts.isAsExpression(node) && node.type.kind === ts.SyntaxKind.AnyKeyword,
    ),
  switch: (sourceFile) =>
    findNodes(sourceFile, (node) => ts.isSwitchStatement(node)),
  "c-style-for": (sourceFile) =>
    findNodes(sourceFile, (node) => ts.isForStatement(node)),
  "const-as-const-enum": (sourceFile) =>
    findNodes(
      sourceFile,
      (node) =>
        ts.isAsExpression(node) &&
        node.type.kind === ts.SyntaxKind.ConstKeyword,
    ),
  "em-dash": (sourceFile) =>
    sourceFile.text.includes("\u2014")
      ? [sourceFile.statements[0] ?? sourceFile]
      : [],
};

const shippedHitKeys = (corpus) => {
  const keys = new Set();
  for (const file of corpus) {
    for (const detector of Object.values(SHIPPED_DETECTORS)) {
      for (const node of detector(file.sourceFile)) {
        if (node?.kind === undefined) continue;
        keys.add(`${file.relPath}:${lineOf(file.sourceFile, node)}`);
      }
    }
  }
  return keys;
};

// ---- candidate loading ------------------------------------------------

const loadCandidates = async () => {
  if (!existsSync(CANDIDATE_DIR)) return [];
  const files = (await readdir(CANDIDATE_DIR))
    .filter((name) => name.endsWith(".mjs"))
    .sort();
  const loaded = [];
  for (const name of files) {
    const url = pathToFileURL(join(CANDIDATE_DIR, name)).href;
    try {
      const module = await import(url);
      const candidate = module.default;
      const source = readFileSync(join(CANDIDATE_DIR, name), "utf8");
      loaded.push({ file: name, candidate, source });
    } catch (error) {
      loaded.push({ file: name, candidate: null, loadError: String(error) });
    }
  }
  return loaded;
};

// ---- run + gate -------------------------------------------------------

const runDetector = (candidate, files) => {
  const byFile = new Map();
  let error = undefined;
  try {
    for (const file of files) {
      const hits = candidate.detect({
        ts,
        sourceFile: file.sourceFile,
        text: file.text,
        lines: file.lines,
        filePath: file.filePath,
        relPath: file.relPath,
        corpus: files,
      });
      if (!hits || hits.length === 0) continue;
      byFile.set(file.relPath, hits);
    }
  } catch (caught) {
    error = String(caught);
  }
  return { byFile, error };
};

const hitKeys = (byFile) => {
  const keys = new Set();
  for (const [relPath, hits] of byFile) {
    for (const hit of hits) keys.add(`${relPath}:${hit.line}`);
  }
  return keys;
};

// the holdout holds several independent projects. a whole-program rule (cycles,
// unused exports, duplicated bodies) must be measured inside one project, never
// across the pool, or every shared template file reads as duplication
const runHoldoutPerProject = (candidate, holdoutFiles) => {
  const projects = new Map();
  for (const file of holdoutFiles) {
    const project = file.relPath.split("/")[0];
    const list = projects.get(project) ?? [];
    list.push(file);
    projects.set(project, list);
  }
  const byFile = new Map();
  let error = undefined;
  for (const projectFiles of projects.values()) {
    const run = runDetector(candidate, projectFiles);
    if (run.error !== undefined) error = run.error;
    for (const [relPath, hits] of run.byFile) byFile.set(relPath, hits);
  }
  return { byFile, error };
};

const overlapRatio = (a, b) => {
  if (a.size === 0) return 0;
  let shared = 0;
  for (const key of a) if (b.has(key)) shared += 1;
  return shared / a.size;
};

// symmetric overlap: a small rule fully contained in a larger but different
// rule is not a duplicate, only a near-identical rule set is
const jaccardOverlap = (a, b) => {
  if (a.size === 0 && b.size === 0) return 0;
  let shared = 0;
  for (const key of a) if (b.has(key)) shared += 1;
  return shared / (a.size + b.size - shared);
};

const evaluate = (
  candidate,
  corpus,
  holdout,
  domainTokens,
  shippedKeys,
  accepted,
  moduleSource,
) => {
  const reasons = [];
  for (const [field, allowed] of [
    ["category", CATEGORIES],
    ["layer", LAYERS],
    ["tier", TIERS],
    ["severity", SEVERITIES],
  ]) {
    if (!allowed.has(candidate[field]))
      reasons.push(`bad_${field}:${candidate[field]}`);
  }
  if (!candidate.id || !candidate.title) reasons.push("missing_id_or_title");
  if ((candidate.rationale ?? "").length < MIN_RATIONALE)
    reasons.push("rationale_too_short");
  if ((candidate.replacement ?? "").length < MIN_REPLACEMENT)
    reasons.push("replacement_too_short");

  const { byFile, error } = runDetector(candidate, corpus);
  if (error) reasons.push(`detector_error`);
  const holdoutRun = runHoldoutPerProject(candidate, holdout);
  const shippedOverlap = overlapRatio(hitKeys(byFile), shippedKeys);
  const noveltyBlocked = EXISTING_PATTERN_KEYS.has(candidate.patternKey);

  // scan all the module's code, not just String(detect), so vocabulary hidden in
  // a module-level helper still trips the gate. comments and the metadata and
  // prose fields are removed first: a rule about "object signatures" is not
  // domain vocabulary just because a corpus file is named signature-*.ts
  const codeSource = moduleSource
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .replace(/^\s*\/\/.*$/gm, "")
    .replace(/\n\s*id:[\s\S]*?\n\s*detect\(/, "\n  detect(");
  // batch 26 amendment, strictness increasing: split every identifier into words with the
  // same camelCase, snake_case and kebab derivation the token list itself uses, then match
  // whole words. a word-boundary match alone let `spiritPenaltyFor` through, demonstrated
  // by the paired controls in section 6.5, so the gate could be evaded by embedding the
  // vocabulary in a longer name
  const codeWords = new Set(
    [...codeSource.matchAll(/[A-Za-z][A-Za-z0-9$_]*/g)]
      .flatMap((match) => match[0].split(/[$_]/))
      .flatMap((part) => part.split(/(?=[A-Z])/))
      .map((word) => word.toLowerCase())
      .filter((word) => word.length >= MIN_DOMAIN_TOKEN),
  );
  const domainHits = [...domainTokens].filter((token) => codeWords.has(token));

  if (reasons.length === 0) {
    if (noveltyBlocked)
      reasons.push(`duplicate_of_shipped:${candidate.patternKey}`);
    if (shippedOverlap > MAX_EXISTING_OVERLAP) {
      reasons.push(`shipped_location_overlap:${shippedOverlap.toFixed(2)}`);
    }
    if (domainHits.length > 0)
      reasons.push(`domain_specific:${domainHits.join("|")}`);
    if (byFile.size < MIN_FILES) reasons.push(`too_few_files:${byFile.size}`);
    const totalHits = [...byFile.values()].reduce(
      (sum, hits) => sum + hits.length,
      0,
    );
    if (totalHits < MIN_HITS) reasons.push(`too_few_hits:${totalHits}`);
    if (totalHits > MAX_HITS || byFile.size > corpus.length * MAX_FILE_SHARE) {
      reasons.push(`too_broad:${totalHits}_hits_${byFile.size}_files`);
    }
    const keys = hitKeys(byFile);
    for (const prior of accepted) {
      // cross-candidate overlap is only a duplicate signal inside one category;
      // different categories are different axes and may legitimately share sites
      if (prior.category !== candidate.category) continue;
      const overlap = jaccardOverlap(keys, prior.keys);
      if (overlap > MAX_CANDIDATE_OVERLAP) {
        reasons.push(`overlaps_candidate:${prior.id}:${overlap.toFixed(2)}`);
        break;
      }
    }
  }

  return {
    candidate,
    byFile,
    holdoutByFile: holdoutRun.byFile,
    totalHits: [...byFile.values()].reduce((sum, hits) => sum + hits.length, 0),
    fileCount: byFile.size,
    holdoutHits: [...holdoutRun.byFile.values()].reduce(
      (sum, hits) => sum + hits.length,
      0,
    ),
    shippedOverlap,
    domainHits,
    reasons,
    verified: reasons.length === 0,
  };
};

// ---- catalogue --------------------------------------------------------

const renderCatalogue = (results, meta) => {
  const verified = results.filter((r) => r.verified);
  const rejected = results.filter((r) => !r.verified);
  const byCategory = new Map();
  for (const r of verified) {
    const list = byCategory.get(r.candidate.category) ?? [];
    list.push(r);
    byCategory.set(r.candidate.category, list);
  }
  const lines = [
    "# grimuah rule candidates from the sleepy research corpus",
    "",
    `generated by docs/rule-candidates/harness.mjs, verified rules: ${verified.length}, corpus: ${meta.corpusFiles} files, holdout: ${meta.holdoutFiles} files`,
    "",
  ];
  for (const [category, entries] of [...byCategory.entries()].sort()) {
    lines.push(`## ${category}`, "");
    for (const entry of entries) {
      const { candidate } = entry;
      lines.push(
        `### ${candidate.id}`,
        "",
        `- layer: ${candidate.layer}, tier: ${candidate.tier}, severity: ${candidate.severity}`,
        `- rule: ${candidate.title}`,
        `- why: ${candidate.rationale}`,
        `- replacement: ${candidate.replacement}`,
        `- hits: ${entry.totalHits} across ${entry.fileCount} files (holdout ${entry.holdoutHits})`,
        "",
        "evidence:",
        "",
      );
      const shown = [];
      for (const [relPath, hits] of [...entry.byFile.entries()].sort()) {
        for (const hit of hits.slice(0, 2))
          shown.push(`  ${relPath}:${hit.line}  ${hit.snippet}`);
        if (shown.length >= 8) break;
      }
      lines.push("```", ...shown, "```", "");
    }
  }
  if (rejected.length > 0) {
    lines.push("## rejected", "");
    for (const entry of rejected) {
      lines.push(
        `- ${entry.candidate?.id ?? entry.file}: ${entry.reasons.join(", ")}`,
      );
    }
    lines.push("");
  }
  return lines.join("\n");
};

// ---- main -------------------------------------------------------------

const main = async () => {
  const corpus = await loadCorpus(CORPUS_ROOTS);
  const holdout = await loadHoldout();
  const domainTokens = deriveDomainTokens(corpus);
  const shippedKeys = shippedHitKeys(corpus);
  const loaded = await loadCandidates();

  const accepted = [];
  const results = [];
  for (const entry of loaded) {
    if (!entry.candidate) {
      results.push({
        candidate: {
          id: entry.file,
          category: "?",
          layer: "?",
          tier: "?",
          severity: "?",
        },
        byFile: new Map(),
        totalHits: 0,
        fileCount: 0,
        holdoutHits: 0,
        reasons: [`load_error:${entry.loadError}`],
        verified: false,
      });
      continue;
    }
    const result = evaluate(
      entry.candidate,
      corpus,
      holdout,
      domainTokens,
      shippedKeys,
      accepted,
      entry.source ?? "",
    );
    if (result.verified)
      accepted.push({
        id: entry.candidate.id,
        category: entry.candidate.category,
        keys: hitKeys(result.byFile),
      });
    results.push(result);
  }

  const verified = results.filter((r) => r.verified);
  const categories = new Set(verified.map((r) => r.candidate.category));
  const catalogue = renderCatalogue(results, {
    corpusFiles: corpus.length,
    holdoutFiles: holdout.length,
  });
  await writeFile(LOCAL_CATALOGUE, `${catalogue}\n`);
  if (!AUTO_CATALOGUE_ONLY) await writeFile(CATALOGUE, `${catalogue}\n`);

  // count rules, not reasons: a rule that fails both too_few_hits and
  // too_few_files is one rejected rule, and the previous version counted it twice
  // in the same counter, so the number moved when a single candidate was added
  const countReasons = (...prefixes) =>
    results.filter((r) =>
      prefixes.some((prefix) =>
        r.reasons.some((reason) => reason.startsWith(prefix)),
      ),
    ).length;

  const width = Math.max(
    ...results.map((r) => (r.candidate.id ?? "").length),
    4,
  );
  for (const r of results) {
    const mark = r.verified ? "PASS" : "fail";
    const detail = r.verified
      ? `${r.totalHits} hits / ${r.fileCount} files / holdout ${r.holdoutHits}`
      : r.reasons.join(", ");
    console.log(
      `${mark}  ${String(r.candidate.id ?? "?").padEnd(width)}  ${r.candidate.category}/${r.candidate.layer}  ${detail}`,
    );
  }

  console.log("");
  console.log(`METRIC verified_rules=${verified.length}`);
  console.log(`METRIC candidate_rules=${results.length}`);
  console.log(`METRIC categories_covered=${categories.size}`);
  console.log(
    `METRIC total_hits=${verified.reduce((sum, r) => sum + r.totalHits, 0)}`,
  );
  console.log(
    `METRIC distinct_files=${new Set(verified.flatMap((r) => [...r.byFile.keys()])).size}`,
  );
  console.log(
    `METRIC holdout_hits=${verified.reduce((sum, r) => sum + r.holdoutHits, 0)}`,
  );
  console.log(
    `METRIC rejected_duplicate=${countReasons("duplicate_of_shipped", "shipped_location_overlap", "overlaps_candidate")}`,
  );
  console.log(`METRIC rejected_overfit=${countReasons("domain_specific")}`);
  console.log(
    `METRIC rejected_low_signal=${countReasons("too_few_hits", "too_few_files", "too_broad")}`,
  );
  console.log(
    `METRIC rejected_malformed=${countReasons("rationale", "replacement", "bad_", "missing_", "load_error", "detector_error")}`,
  );
};

main().catch((error) => {
  console.error("harness failed", error);
  process.exit(1);
});
