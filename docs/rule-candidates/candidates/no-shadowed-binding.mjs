let cachedCorpus;

// names a file introduces at its top level: imports and top-level declarations.
// a declaration inside a function that reuses one of these, or one from an
// enclosing function, is a second binding wearing the first one's name
const moduleScopeNames = (ts, sourceFile) => {
  const names = new Set();
  for (const statement of sourceFile.statements) {
    if (
      ts.isImportDeclaration(statement) &&
      statement.importClause !== undefined
    ) {
      const clause = statement.importClause;
      if (clause.name !== undefined) names.add(clause.name.text);
      const collectSpecifiers = (inner) => {
        if (ts.isImportSpecifier(inner)) names.add(inner.name.text);
        ts.forEachChild(inner, collectSpecifiers);
      };
      collectSpecifiers(clause);
    }
    if (
      (ts.isFunctionDeclaration(statement) ||
        ts.isTypeAliasDeclaration(statement) ||
        ts.isEnumDeclaration(statement) ||
        ts.isClassDeclaration(statement)) &&
      statement.name !== undefined
    ) {
      names.add(statement.name.text);
    }
    if (ts.isVariableStatement(statement)) {
      for (const declaration of statement.declarationList.declarations) {
        if (ts.isIdentifier(declaration.name)) names.add(declaration.name.text);
      }
    }
  }
  return names;
};

// declarations at one function's own scope level. the walk deliberately stops at
// a nested function, otherwise a name declared in a child is counted as living in
// the parent too and the child then reports it as shadowing itself
const declaredInside = (ts, body) => {
  const found = [];
  const visit = (node) => {
    if (ts.isVariableDeclaration(node) && ts.isIdentifier(node.name))
      found.push(node.name);
    if (ts.isFunctionDeclaration(node) && node.name !== undefined)
      found.push(node.name);
    if (ts.isFunctionLike(node)) return;
    ts.forEachChild(node, visit);
  };
  if (body !== undefined) visit(body);
  return found;
};

const parameterNames = (ts, node) => {
  const names = new Set();
  for (const parameter of node.parameters ?? []) {
    if (ts.isIdentifier(parameter.name)) names.add(parameter.name.text);
  }
  return names;
};

export default {
  id: "no-shadowed-binding",
  category: "complexity",
  layer: "resilience",
  tier: "grit",
  severity: "warn",
  patternKey: "shadowed-binding",
  title:
    "a declaration inside a function must not reuse a name from an enclosing scope",
  rationale:
    "the inner binding silently replaces the outer one for the rest of that function, so the reader who learned what the outer name holds now has to re-learn it partway down, and the outer value they meant to use is still reachable a few lines earlier, which is how a fix gets applied to the wrong variable and still compiles",
  replacement:
    "give the inner binding its own name that says what it holds, or reuse the outer binding instead of re-declaring it",
  detect({ ts, sourceFile }) {
    const hits = [];
    const visit = (node, outerNames) => {
      if (ts.isFunctionLike(node)) {
        const innerNames = new Set(outerNames);
        for (const name of parameterNames(ts, node)) innerNames.add(name);
        for (const declaredName of declaredInside(ts, node.body)) {
          if (outerNames.has(declaredName.text)) {
            const position = sourceFile.getLineAndCharacterOfPosition(
              declaredName.getStart(sourceFile),
            );
            hits.push({
              line: position.line + 1,
              column: position.character + 1,
              snippet: `${declaredName.text} reuses a name from an enclosing scope`,
            });
          }
          innerNames.add(declaredName.text);
        }
        ts.forEachChild(node, (child) => visit(child, innerNames));
        return;
      }
      ts.forEachChild(node, (child) => visit(child, outerNames));
    };
    visit(sourceFile, moduleScopeNames(ts, sourceFile));
    return hits;
  },
};
