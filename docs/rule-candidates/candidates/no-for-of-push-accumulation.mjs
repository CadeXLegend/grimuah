const ACCUMULATOR_CALLS = new Set(["push", "unshift"]);

export default {
  id: "no-for-of-push-accumulation",
  category: "declarative",
  layer: "resilience",
  tier: "grit",
  severity: "error",
  patternKey: "for-of-accumulation",
  title: "a for..of loop must not build an array by pushing into it",
  rationale:
    "a loop that pushes into an array is a map, a filter or a reduce written the long way, the reader has to run the loop in their head to learn what the result contains, the accumulator is a mutable binding the rule set otherwise forbids, and the loop body hides whether elements are kept, dropped or transformed",
  replacement:
    "express the transformation with map, filter, flatMap or reduce, and when the body is genuinely side-effecting, keep the for..of but drop the accumulator",
  detect({ ts, sourceFile }) {
    const hits = [];
    const holdsFunction = (node) =>
      ts.isFunctionDeclaration(node) ||
      ts.isFunctionExpression(node) ||
      ts.isArrowFunction(node) ||
      ts.isMethodDeclaration(node);
    const pushesIntoAccumulator = (node) => {
      let found = false;
      const scan = (inner) => {
        if (found || holdsFunction(inner)) return;
        if (
          ts.isCallExpression(inner) &&
          ts.isPropertyAccessExpression(inner.expression) &&
          ACCUMULATOR_CALLS.has(inner.expression.name.text)
        ) {
          found = true;
          return;
        }
        ts.forEachChild(inner, scan);
      };
      scan(node);
      return found;
    };
    const visit = (node) => {
      if (ts.isForOfStatement(node) && pushesIntoAccumulator(node.statement)) {
        const position = sourceFile.getLineAndCharacterOfPosition(
          node.getStart(sourceFile),
        );
        hits.push({
          line: position.line + 1,
          column: position.character + 1,
          snippet: node.getText(sourceFile).replace(/\s+/g, " ").slice(0, 120),
        });
        return;
      }
      ts.forEachChild(node, visit);
    };
    visit(sourceFile);
    return hits;
  },
};
