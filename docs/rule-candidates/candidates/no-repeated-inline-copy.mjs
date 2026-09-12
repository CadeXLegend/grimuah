// user-facing copy or statement text written more than once inside a single
// source file. the terminal punctuation is the project's own marker for a
// sentence rather than a log line, and copy that is pasted into two statements
// in one file is two copies that will be edited apart the first time the
// wording changes
//
// a .config.ts file is out of scope by construction: the first half of the fix
// is to declare the sentence there, so a repeat inside one is a duplicate data
// entry rather than an undeclared copy, and a different rule's problem
const MINIMUM_COPY_LENGTH = 8;
const MINIMUM_OCCURRENCES = 2;
const SENTENCE_END = /[.!?]$/;

const isCopyDeclaration = (relPath) => relPath.endsWith(".config.ts");

export default {
  id: "no-repeated-inline-copy",
  category: "patterns",
  layer: "cosmetic",
  tier: "prepass",
  severity: "warn",
  patternKey: "repeated-copy-in-file",
  title: "user-facing copy must not be written out twice inside one file",
  rationale:
    "the cross-file copy rule only sees a sentence once it has spread to three files, so the smallest and most common form of the defect is invisible: two statements in one file carrying the same sentence, where a wording change updates one of them and leaves the other saying something the author no longer means, and neither copy is reachable from the config entry that owns the rest of the surface's copy",
  replacement:
    "declare the sentence once, as an entry in the owning .config.ts where the surface already keeps its user-facing text or as a module-level constant otherwise, and let every statement name that entry instead of repeating the sentence",
  detect({ ts, sourceFile, relPath }) {
    if (relPath.endsWith(".d.ts") || isCopyDeclaration(relPath)) return [];
    const occurrences = new Map();
    const visit = (node) => {
      if (
        ts.isStringLiteralLike(node) &&
        node.parent !== undefined &&
        !ts.isImportDeclaration(node.parent) &&
        node.text.length >= MINIMUM_COPY_LENGTH &&
        /\s/.test(node.text) &&
        SENTENCE_END.test(node.text)
      ) {
        const sites = occurrences.get(node.text) ?? [];
        sites.push(node);
        occurrences.set(node.text, sites);
      }
      ts.forEachChild(node, visit);
    };
    visit(sourceFile);

    const hits = [];
    for (const [sentence, sites] of occurrences) {
      if (sites.length < MINIMUM_OCCURRENCES) continue;
      for (const site of sites) {
        const position = sourceFile.getLineAndCharacterOfPosition(
          site.getStart(sourceFile),
        );
        hits.push({
          line: position.line + 1,
          column: position.character + 1,
          snippet: `${JSON.stringify(sentence.slice(0, 50))} written ${sites.length} times in this file`,
        });
      }
    }
    return hits;
  },
};
