const STATEMENT_START = /^\s*(SELECT|INSERT|UPDATE|DELETE|WITH|REPLACE)\b/i;

let cachedCorpus;
let cachedGroups;

// the statement text, whitespace collapsed. two copies that differ only in how
// they are wrapped are the same statement
const normalize = (text) => text.replace(/\s+/g, " ").trim();

const collectGroups = (ts, corpus) => {
  const groups = new Map();
  for (const file of corpus) {
    const visit = (node) => {
      if (ts.isStringLiteral(node) && STATEMENT_START.test(node.text)) {
        const text = normalize(node.text);
        const entry = groups.get(text) ?? { files: new Set(), count: 0 };
        entry.files.add(file.relPath);
        entry.count += 1;
        groups.set(text, entry);
        return;
      }
      ts.forEachChild(node, visit);
    };
    visit(file.sourceFile);
  }
  return groups;
};

export default {
  id: "no-duplicated-statement-text",
  category: "sql",
  layer: "resilience",
  tier: "prepass",
  severity: "warn",
  patternKey: "duplicated-statement",
  title:
    "a statement written twice must be declared once and shared by both call sites",
  rationale:
    "a statement is the contract a module keeps with the shape of its rows, so two copies are two contracts that drift apart: a column added to one and not the other leaves two spellings of the same fact, and the failure is silent because both copies run. a shared receiver hides the repeat from every other duplication check, since one call site prepares it on a handle named for one table and the other prepares it on a handle named for another, and the statement text is the only part that must not be written twice.",
  replacement:
    "declare the statement once as a module level constant, or as one exported helper both call sites call, so the text has one home and a schema change is one edit.",
  detect({ ts, sourceFile, relPath, corpus }) {
    if (cachedCorpus !== corpus) {
      cachedCorpus = corpus;
      cachedGroups = collectGroups(ts, corpus);
    }
    const hits = [];
    const visit = (node) => {
      if (ts.isStringLiteral(node) && STATEMENT_START.test(node.text)) {
        const text = normalize(node.text);
        const entry = cachedGroups.get(text);
        if (entry !== undefined && entry.count >= 2) {
          const position = sourceFile.getLineAndCharacterOfPosition(
            node.getStart(sourceFile),
          );
          hits.push({
            line: position.line + 1,
            column: position.character + 1,
            snippet: `written ${entry.count} times across ${entry.files.size} files: ${text.slice(0, 70)}`,
          });
        }
        return;
      }
      ts.forEachChild(node, visit);
    };
    visit(sourceFile);
    void relPath;
    return hits;
  },
};
