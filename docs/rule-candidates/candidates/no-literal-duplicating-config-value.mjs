let cachedCorpus;
let cachedEnumValuesBySurface;

// collect every string value an enum declares, keyed by the SURFACE, which is
// the config file's own name: a surface's config sits beside its implementation
// as `<stem>.config.ts`, so `afk.service.config.ts` belongs to `afk.service.ts`
// and to nothing else.
//
// this replaced a scope keyed by directory. in `gateway/` and at the root a
// directory holds one surface, so the two readings agree, but `src/services/`
// holds 40 files and 15 configs, so a directory scope let a literal match a
// SIBLING surface's value. three of the rule's 21 hits were that artifact:
// `divination.service.ts:40` and `family-tree.service.ts:146` carry `":"` and
// matched the nine `CustomIdSeparator = ":"` declarations around them, and
// `guide-shelf.service.ts:165` carries `"second"` and matched
// `DreamJourneyVisitTier.Second`. this is section 6.3's rule applied: key on a
// convention the corpus owner controls, never on a path position
const surfaceOfConfig = (relPath) => relPath.replace(/\.config\.ts$/, "");
const surfaceOfConsumer = (relPath) => relPath.replace(/\.ts$/, "");

const collectEnumValues = (ts, corpus) => {
  const bySurface = new Map();
  for (const file of corpus) {
    if (!file.relPath.endsWith(".config.ts")) continue;
    const surface = surfaceOfConfig(file.relPath);
    const values = bySurface.get(surface) ?? new Map();
    const visit = (node) => {
      if (ts.isEnumDeclaration(node)) {
        for (const declaration of node.members) {
          const initializer = declaration.initializer;
          if (
            initializer !== undefined &&
            ts.isStringLiteralLike(initializer)
          ) {
            const owners = values.get(initializer.text) ?? [];
            owners.push(`${node.name.text}.${declaration.name.getText()}`);
            values.set(initializer.text, owners);
          }
        }
      }
      ts.forEachChild(node, visit);
    };
    visit(file.sourceFile);
    bySurface.set(surface, values);
  }
  return bySurface;
};

export default {
  id: "no-literal-duplicating-config-value",
  category: "patterns",
  layer: "cosmetic",
  tier: "prepass",
  severity: "warn",
  patternKey: "literal-duplicating-config-value",
  title:
    "a string literal must not retype a value the surface's own config already declares",
  rationale:
    "the enum is the single source of truth for the value, and the literal is a second copy that the compiler cannot keep in step, changing the enum silently leaves the literal comparing against the old text, and a reader cannot tell whether the match is deliberate or whether it used to be a different value",
  replacement:
    "import the enum and reference the declaration, so a rename or a value change is a one-line edit that every comparison follows",
  detect({ ts, sourceFile, relPath, corpus }) {
    if (relPath.endsWith(".config.ts") || relPath.endsWith(".d.ts")) return [];
    if (cachedCorpus !== corpus) {
      cachedCorpus = corpus;
      cachedEnumValuesBySurface = collectEnumValues(ts, corpus);
    }
    const enumValues = cachedEnumValuesBySurface.get(
      surfaceOfConsumer(relPath),
    );
    if (enumValues === undefined) return [];
    const hits = [];
    const visit = (node) => {
      if (ts.isStringLiteralLike(node) && enumValues.has(node.text)) {
        const position = sourceFile.getLineAndCharacterOfPosition(
          node.getStart(sourceFile),
        );
        hits.push({
          line: position.line + 1,
          column: position.character + 1,
          snippet: `${node.getText(sourceFile)} duplicates ${enumValues.get(node.text).slice(0, 2).toString()}`,
        });
      }
      ts.forEachChild(node, visit);
    };
    visit(sourceFile);
    return hits;
  },
};
