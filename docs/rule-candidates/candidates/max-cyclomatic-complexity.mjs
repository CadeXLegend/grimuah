const MAX_CYCLOMATIC_COMPLEXITY = 15;

const BRANCH_KINDS = new Set([
  "IfStatement",
  "ConditionalExpression",
  "CaseClause",
  "CatchClause",
  "ForStatement",
  "ForInStatement",
  "ForOfStatement",
  "WhileStatement",
  "DoStatement",
]);

const SHORT_CIRCUIT_KINDS = new Set([
  "AmpersandAmpersandToken",
  "BarBarToken",
  "QuestionQuestionToken",
]);

export default {
  id: "max-cyclomatic-complexity",
  category: "complexity",
  layer: "resilience",
  tier: "grit",
  severity: "warn",
  patternKey: "cyclomatic-complexity",
  title: `a function must not exceed cyclomatic complexity ${MAX_CYCLOMATIC_COMPLEXITY}`,
  rationale:
    "cyclomatic complexity counts the independent paths a reader must hold in their head at once, a function past the threshold is one where each new branch silently doubles the states to reason about, tests stop covering the branches and start covering the happy path, and the function is usually several decisions that were never separated",
  replacement:
    "extract each decision into a named predicate or lookup, replace branch chains with a Record dispatch table, and move the removed cases into their own functions with their own names",
  detect({ ts, sourceFile }) {
    const hits = [];
    const visit = (node) => {
      const isMeasuredFunction =
        ts.isFunctionLike(node) &&
        node.body !== undefined &&
        ts.isBlock(node.body);
      if (isMeasuredFunction) {
        let complexity = 1;
        const scan = (inner) => {
          const kindName = ts.SyntaxKind[inner.kind];
          if (BRANCH_KINDS.has(kindName)) complexity += 1;
          if (
            ts.isBinaryExpression(inner) &&
            SHORT_CIRCUIT_KINDS.has(ts.SyntaxKind[inner.operatorToken.kind])
          ) {
            complexity += 1;
          }
          ts.forEachChild(inner, scan);
        };
        scan(node.body);
        if (complexity > MAX_CYCLOMATIC_COMPLEXITY) {
          const position = sourceFile.getLineAndCharacterOfPosition(
            node.getStart(sourceFile),
          );
          hits.push({
            line: position.line + 1,
            column: position.character + 1,
            snippet: `complexity ${complexity} -- ${node.getText(sourceFile).replace(/\s+/g, " ").slice(0, 90)}`,
          });
        }
      }
      ts.forEachChild(node, visit);
    };
    visit(sourceFile);
    return hits;
  },
};
