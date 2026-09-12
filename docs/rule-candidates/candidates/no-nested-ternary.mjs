// walk upward past parenthesised wrappers, a ternary that is merely wrapped in
// parens is not nested inside another ternary
const enclosingExpression = (ts, node) => {
  let parent = node.parent;
  while (parent !== undefined && ts.isParenthesizedExpression(parent))
    parent = parent.parent;
  return parent;
};

export default {
  id: "no-nested-ternary",
  category: "complexity",
  layer: "resilience",
  tier: "grit",
  severity: "warn",
  patternKey: "nested-ternary",
  title:
    "a conditional expression must not contain another conditional expression",
  rationale:
    "a ternary nested in a ternary turns a two-branch decision into a tree the reader must evaluate branch by branch, the conditions read in one direction and the results in another, and the shape is exactly the case a lookup table or an early return expresses directly",
  replacement:
    "extract the inner decision into a named helper, look the branch up in a Record, or replace the chain with early returns when it chooses between statements",
  detect({ ts, sourceFile }) {
    const hits = [];
    const visit = (node) => {
      if (ts.isConditionalExpression(node)) {
        const parent = enclosingExpression(ts, node);
        if (parent !== undefined && ts.isConditionalExpression(parent)) {
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
        }
      }
      ts.forEachChild(node, visit);
    };
    visit(sourceFile);
    return hits;
  },
};
