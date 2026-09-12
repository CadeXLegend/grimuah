// the call-site half of the scalar sentinel finding. a function that settles to
// a bare boolean or number has no way to say why it failed, so a call whose
// result nobody reads is a failure channel that exists only in the signature
const SCALAR_SETTLED_TYPES = new Set(["Promise<boolean>", "Promise<number>"]);

let cachedCorpus;
let cachedReturnTypes;

// whole-program map of declared function name to its declared return type text.
// a name declared more than once keeps every declaration, so a call is only
// judged when every candidate declaration agrees it settles to a scalar
const collectReturnTypes = (ts, corpus) => {
  const returnTypes = new Map();
  const add = (name, typeText) => {
    const list = returnTypes.get(name) ?? [];
    list.push(typeText);
    returnTypes.set(name, list);
  };
  for (const file of corpus) {
    for (const statement of file.sourceFile.statements) {
      if (
        ts.isFunctionDeclaration(statement) &&
        statement.name !== undefined &&
        statement.type !== undefined
      ) {
        add(statement.name.text, statement.type.getText(file.sourceFile));
      }
      if (ts.isVariableStatement(statement)) {
        for (const declaration of statement.declarationList.declarations) {
          const initializer = declaration.initializer;
          const isFunction =
            initializer !== undefined &&
            (ts.isArrowFunction(initializer) ||
              ts.isFunctionExpression(initializer));
          if (
            ts.isIdentifier(declaration.name) &&
            isFunction &&
            initializer.type !== undefined
          ) {
            add(
              declaration.name.text,
              initializer.type.getText(file.sourceFile),
            );
          }
        }
      }
    }
  }
  return returnTypes;
};

const calleeNameOf = (ts, expression) => {
  if (ts.isIdentifier(expression)) return expression.text;
  if (ts.isPropertyAccessExpression(expression)) return expression.name.text;
  return undefined;
};

export default {
  id: "no-unread-scalar-result",
  category: "resilience",
  layer: "behavioural",
  tier: "prepass",
  severity: "warn",
  patternKey: "unread-scalar-result",
  title:
    "a call whose declared result is a bare boolean or number must have that result read",
  rationale:
    "a function that settles to a scalar can only report failure by returning the value that also means a real answer, so when the caller drops the result the operation has neither reported its failure nor been told to, the failure channel exists only in the signature, and the reader of the call site cannot tell whether the author decided the result did not matter or never noticed there was one",
  replacement:
    "read the result and act on it, or where the call is genuinely best effort, log the failure at the call site so the intent is stated, or narrow the callee to a void result so the signature stops claiming a failure the caller never consumes",
  detect({ ts, sourceFile, corpus }) {
    if (cachedCorpus !== corpus) {
      cachedCorpus = corpus;
      cachedReturnTypes = collectReturnTypes(ts, corpus);
    }
    const returnTypes = cachedReturnTypes;
    const hits = [];
    const visit = (node) => {
      if (!ts.isExpressionStatement(node)) {
        ts.forEachChild(node, visit);
        return;
      }
      const settledExpression = ts.isAwaitExpression(node.expression)
        ? node.expression.expression
        : node.expression;
      // void f() is the explicit marker of a dropped result, so it is the same
      // defect stated on purpose rather than the same defect by omission
      const expression = ts.isVoidExpression(settledExpression)
        ? settledExpression.expression
        : settledExpression;
      if (ts.isCallExpression(expression)) {
        const name = calleeNameOf(ts, expression.expression);
        const declaredTypes =
          name === undefined ? undefined : returnTypes.get(name);
        const alwaysScalar =
          declaredTypes !== undefined &&
          declaredTypes.length > 0 &&
          declaredTypes.every((typeText) => SCALAR_SETTLED_TYPES.has(typeText));
        if (alwaysScalar) {
          const position = sourceFile.getLineAndCharacterOfPosition(
            node.getStart(sourceFile),
          );
          hits.push({
            line: position.line + 1,
            column: position.character + 1,
            snippet: `${node.getText(sourceFile).replace(/\s+/g, " ").slice(0, 100)} -- settles to ${declaredTypes[0]}`,
          });
        }
      }
      ts.forEachChild(node, visit);
    };
    visit(sourceFile);
    return hits;
  },
};
