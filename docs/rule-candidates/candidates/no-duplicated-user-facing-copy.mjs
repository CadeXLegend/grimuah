const MINIMUM_COPY_LENGTH = 24;
const DUPLICATE_FILE_THRESHOLD = 3;

let cachedCorpus;
let cachedOwners;

// a user-facing sentence is any literal long enough to be copy rather than a
// key, with at least one space between letters so identifiers are excluded
const isCopy = (text) =>
  text.length >= MINIMUM_COPY_LENGTH && /[a-zA-Z] [a-zA-Z]/.test(text);

const collectCopyOwners = (ts, corpus) => {
  const owners = new Map();
  for (const file of corpus) {
    const visit = (node) => {
      if (ts.isStringLiteralLike(node) && isCopy(node.text)) {
        const sites = owners.get(node.text) ?? [];
        sites.push(file.relPath);
        owners.set(node.text, sites);
      }
      ts.forEachChild(node, visit);
    };
    visit(file.sourceFile);
  }
  return owners;
};

export default {
  id: "no-duplicated-user-facing-copy",
  category: "patterns",
  layer: "cosmetic",
  tier: "prepass",
  severity: "warn",
  patternKey: "duplicated-copy",
  title: `the same user-facing sentence must not be written out in ${DUPLICATE_FILE_THRESHOLD} or more files`,
  rationale:
    "copy that is pasted into each file drifts the moment one site is edited, the reader cannot tell whether two identical sentences are the same message or two messages that happen to match today, and a wording change becomes a search across the codebase instead of one edit at the owning constant",
  replacement:
    "declare the sentence once in the owning surface's .config.ts enum and import it, or lift it to lib when several surfaces share it, keeping the literal only where the duplication is deliberate across process boundaries",
  detect({ ts, sourceFile, relPath, corpus }) {
    if (relPath.endsWith(".d.ts")) return [];
    if (cachedCorpus !== corpus) {
      cachedCorpus = corpus;
      cachedOwners = collectCopyOwners(ts, corpus);
    }
    const owners = cachedOwners;
    const hits = [];
    const visit = (node) => {
      if (ts.isStringLiteralLike(node) && isCopy(node.text)) {
        const distinctFiles = new Set(owners.get(node.text) ?? []);
        if (distinctFiles.size >= DUPLICATE_FILE_THRESHOLD) {
          const position = sourceFile.getLineAndCharacterOfPosition(
            node.getStart(sourceFile),
          );
          hits.push({
            line: position.line + 1,
            column: position.character + 1,
            snippet: `${JSON.stringify(node.text.slice(0, 60))} also appears in ${distinctFiles.size - 1} other file(s)`,
          });
        }
      }
      ts.forEachChild(node, visit);
    };
    visit(sourceFile);
    return hits;
  },
};
