const MINIMUM_COPY_LENGTH = 12;

// copy rather than a key: long enough to be a sentence and containing a space
// between letters, which excludes enum values like "nowplaying" and ids
const isCopy = (text) =>
  text.length >= MINIMUM_COPY_LENGTH && /[a-zA-Z] [a-zA-Z]/.test(text);

const firstChunkOf = (ts, node) => {
  if (ts.isStringLiteralLike(node)) return { text: node.text, at: node };
  if (ts.isTemplateExpression(node))
    return { text: node.head.text, at: node.head };
  return undefined;
};

export default {
  id: "require-capitalised-user-facing-copy",
  category: "patterns",
  layer: "cosmetic",
  tier: "grit",
  severity: "warn",
  patternKey: "lowercase-copy",
  title: "user-facing copy must start with a capital letter",
  rationale:
    "copy that starts lowercase reaches the user as a sentence fragment, the same message renders differently depending on whether it is shown alone or spliced after another line, and a rule the project already documents stops being enforceable the moment it lives only in a style guide",
  replacement:
    "capitalise the first letter of the sentence, keeping proper nouns and inline identifiers as they are, and keep template placeholders out of the first position so the capital is not swallowed by substitution",
  detect({ ts, sourceFile, relPath }) {
    if (!relPath.endsWith(".config.ts")) return [];
    const hits = [];
    const visit = (node) => {
      const chunk = firstChunkOf(ts, node);
      if (
        chunk !== undefined &&
        chunk.text.length > 0 &&
        /^[a-z]/.test(chunk.text) &&
        isCopy(chunk.text)
      ) {
        const position = sourceFile.getLineAndCharacterOfPosition(
          node.getStart(sourceFile),
        );
        hits.push({
          line: position.line + 1,
          column: position.character + 1,
          snippet: node.getText(sourceFile).replace(/\s+/g, " ").slice(0, 120),
        });
      }
      ts.forEachChild(node, visit);
    };
    visit(sourceFile);
    return hits;
  },
};
