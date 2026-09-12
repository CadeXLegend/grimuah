import { basename } from "node:path";

// the subject a branch tests. a comparison is about its left side, a predicate call is
// about its argument, anything else is itself. requiring every branch to test the same
// subject is what separates a dispatch from a run of unrelated guard clauses, and it is
// the whole precision of the rule
const subjectOf = (ts, sourceFile, condition) => {
  let current = condition;
  if (ts.isPrefixUnaryExpression(current)) current = current.operand;
  if (ts.isParenthesizedExpression(current)) current = current.expression;
  if (ts.isBinaryExpression(current)) return current.left.getText(sourceFile);
  if (ts.isCallExpression(current)) {
    const onlyArgument =
      current.arguments.length === 1 ? current.arguments[0] : undefined;
    return onlyArgument === undefined
      ? current.getText(sourceFile)
      : onlyArgument.getText(sourceFile);
  }
  return current.getText(sourceFile);
};

const branchReturns = (ts, statement) => {
  if (ts.isReturnStatement(statement)) return true;
  if (ts.isBlock(statement))
    return (
      statement.statements.length === 1 &&
      ts.isReturnStatement(statement.statements[0])
    );
  return false;
};

export default {
  id: "no-if-chain-dispatch",
  category: "declarative",
  layer: "resilience",
  tier: "grit",
  severity: "warn",
  patternKey: "if-chain-dispatch",
  title: "a run of three or more branches over one subject is a dispatch table",
  rationale:
    "the shipped switch ban states the intent as use a dispatch table, and an if-chain of predicate tests and early returns is the same construct with the same properties: one linear scan, one function to edit to add a case, and no place that lists the cases. it also passes the ban. the run is recognisable without types because every branch tests the same subject and every branch returns, which is what separates a dispatch from a run of unrelated guards",
  replacement:
    "declare a Record or Map from the subject's value to the handler and look the branch up, so adding a case is adding an entry and the set of cases is a value a reader can see. keep the if-chain when the branches test genuinely different conditions rather than different values of one subject",
  detect({ ts, sourceFile }) {
    const hits = [];
    const report = (subjects, branchCount, firstNode) => {
      const position = sourceFile.getLineAndCharacterOfPosition(
        firstNode.getStart(sourceFile),
      );
      hits.push({
        line: position.line + 1,
        column: position.character + 1,
        snippet: `${branchCount} branches dispatched on ${subjects.replace(/\s+/g, " ").slice(0, 90)}`,
      });
    };
    const reportIfDispatch = (branches) => {
      if (branches.length < 3) return;
      const subjects = new Set(branches.map((branch) => branch.subject));
      if (subjects.size !== 1) return;
      report(branches[0].subject, branches.length, branches[0].node);
    };
    const scanStatements = (statements) => {
      // shape one: a sequence of sibling if-returns with no else. the sequence is grouped
      // by subject, because a dispatch run is often preceded by one unrelated guard and
      // requiring the whole sequence to agree would hide every such run
      let group = [];
      const flushGroup = () => {
        reportIfDispatch(group);
        group = [];
      };
      for (const statement of statements) {
        const isBranch =
          ts.isIfStatement(statement) &&
          statement.elseStatement === undefined &&
          branchReturns(ts, statement.thenStatement);
        if (!isBranch) {
          flushGroup();
          continue;
        }
        const subject = subjectOf(ts, sourceFile, statement.expression);
        if (group.length > 0 && group[0].subject !== subject) flushGroup();
        group.push({ node: statement, subject });
      }
      flushGroup();
    };
    const scanChain = (ifStatement) => {
      // only a chain head counts, otherwise an n branch chain reports itself n minus two times
      const parent = ifStatement.parent;
      if (
        parent !== undefined &&
        ts.isIfStatement(parent) &&
        parent.elseStatement === ifStatement
      )
        return;
      const branches = [];
      let current = ifStatement;
      for (;;) {
        branches.push({
          node: current,
          subject: subjectOf(ts, sourceFile, current.expression),
        });
        const next = current.elseStatement;
        if (next === undefined) break;
        if (!ts.isIfStatement(next)) return;
        current = next;
      }
      reportIfDispatch(branches);
    };
    const visit = (node) => {
      if (ts.isBlock(node)) scanStatements(node.statements);
      if (ts.isCaseClause(node) || ts.isDefaultClause(node))
        scanStatements(node.statements);
      if (ts.isIfStatement(node)) scanChain(node);
      ts.forEachChild(node, visit);
    };
    visit(sourceFile);
    return hits;
  },
};
