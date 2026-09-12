const LOOP_KINDS = new Set([
  "ForStatement",
  "ForInStatement",
  "ForOfStatement",
  "WhileStatement",
  "DoStatement",
]);

export default {
  id: "no-await-in-loop",
  category: "performance",
  layer: "behavioural",
  tier: "grit",
  severity: "warn",
  patternKey: "await-in-loop",
  title: "an await inside a loop serialises every iteration",
  rationale:
    "an await in a loop body suspends once per element, so a loop over n items costs n sequential round trips instead of one concurrent batch, the latency is n times the slowest dependency and the pattern silently turns a linear scan into the dominant cost of the request",
  replacement:
    "map the items to promises and await Promise.all once, or use Promise.allSettled when one rejection must not cancel the rest, and keep the loop only when iteration n truly depends on iteration n minus one",
  detect({ ts, sourceFile }) {
    const hits = [];
    const holdsFunction = (node) =>
      ts.isFunctionDeclaration(node) ||
      ts.isFunctionExpression(node) ||
      ts.isArrowFunction(node) ||
      ts.isMethodDeclaration(node);
    const containsAwait = (node) => {
      let found = false;
      const scan = (inner) => {
        if (found) return;
        if (holdsFunction(inner)) return;
        if (ts.isAwaitExpression(inner)) {
          found = true;
          return;
        }
        ts.forEachChild(inner, scan);
      };
      scan(node);
      return found;
    };
    const visit = (node) => {
      if (LOOP_KINDS.has(ts.SyntaxKind[node.kind])) {
        if (containsAwait(node.statement)) {
          const position = sourceFile.getLineAndCharacterOfPosition(
            node.getStart(sourceFile),
          );
          hits.push({
            line: position.line + 1,
            column: position.character + 1,
            snippet: node
              .getText(sourceFile)
              .replace(/\s+/g, " ")
              .slice(0, 120),
          });
          return;
        }
      }
      ts.forEachChild(node, visit);
    };
    visit(sourceFile);
    return hits;
  },
};
