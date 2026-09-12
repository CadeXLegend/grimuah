let cachedCorpus;
let cachedReturnTypes;

// whole-program map of declared function name to its declared return type text
// a name declared more than once keeps every declaration so a call is only
// judged when every candidate declaration agrees it returns an outcome
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
  id: "no-discarded-outcome",
  category: "resilience",
  layer: "behavioural",
  tier: "grit",
  severity: "warn",
  patternKey: "discarded-outcome",
  title: "a call that returns Outcome must have its succeeded field narrowed",
  rationale:
    "the behavioural layer routes every failure through an Outcome so the caller cannot forget it, but an Outcome used as a bare statement is discarded before it is read, the failure branch becomes unreachable and the error disappears with no log and no return, which is the exact silent failure the Outcome pattern was introduced to prevent",
  replacement:
    "assign the result and branch on succeeded, returning a matching failure when the call fails, and where the call is genuinely best effort, say so by logging the failure instead of dropping the value",
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
      const expression = ts.isAwaitExpression(node.expression)
        ? node.expression.expression
        : node.expression;
      if (ts.isCallExpression(expression)) {
        const name = calleeNameOf(ts, expression.expression);
        const declaredTypes =
          name === undefined ? undefined : returnTypes.get(name);
        const alwaysOutcome =
          declaredTypes !== undefined &&
          declaredTypes.length > 0 &&
          declaredTypes.every((typeText) => typeText.includes("Outcome"));
        if (alwaysOutcome) {
          const position = sourceFile.getLineAndCharacterOfPosition(
            node.getStart(sourceFile),
          );
          hits.push({
            line: position.line + 1,
            column: position.character + 1,
            snippet: `${node.getText(sourceFile).replace(/\s+/g, " ").slice(0, 100)} -- returns ${declaredTypes[0]}`,
          });
        }
      }
      ts.forEachChild(node, visit);
    };
    visit(sourceFile);
    return hits;
  },
};
