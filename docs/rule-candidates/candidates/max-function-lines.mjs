const MAX_FUNCTION_LINES = 80;

export default {
  id: "max-function-lines",
  category: "complexity",
  layer: "resilience",
  tier: "grit",
  severity: "warn",
  patternKey: "function-length",
  title: `a function body must not exceed ${MAX_FUNCTION_LINES} lines`,
  rationale:
    "a long function accumulates responsibilities because every addition looks local, the name stops describing the whole body, and the only way to test one branch is to reproduce the state the earlier branches built, length is the cheapest proxy for how many jobs a function is doing",
  replacement:
    "extract each distinct job into a named function with its own return type and leave the original as an ordered sequence of calls",
  detect({ ts, sourceFile }) {
    const hits = [];
    const visit = (node) => {
      const isFunctionBody = ts.isFunctionLike(node) && node.body !== undefined;
      if (isFunctionBody) {
        const startLine = sourceFile.getLineAndCharacterOfPosition(
          node.body.getStart(sourceFile),
        ).line;
        const endLine = sourceFile.getLineAndCharacterOfPosition(
          node.body.getEnd(),
        ).line;
        if (endLine - startLine > MAX_FUNCTION_LINES) {
          const position = sourceFile.getLineAndCharacterOfPosition(
            node.getStart(sourceFile),
          );
          hits.push({
            line: position.line + 1,
            column: position.character + 1,
            snippet: `${endLine - startLine} lines -- ${node.getText(sourceFile).replace(/\s+/g, " ").slice(0, 90)}`,
          });
        }
      }
      ts.forEachChild(node, visit);
    };
    visit(sourceFile);
    return hits;
  },
};
