// a statement container deeper than three layers inside one function, method or
// class body.
//
// what does not count as a layer:
//   - the innate brace of a function, method, class or arrow body, so a nested
//     function body starts its own count at zero
//   - the block body of a control statement, because `if (x) { ... }` is one
//     layer and not two
//   - the case bodies of a switch, because the cases are alternatives at one
//     layer and not a descent
//   - an `else if` continuation, because an if/else-if ladder is flat
//
// what counts as a layer: a block that stands on its own, and a control
// statement that owns a body. braces are not required: a braceless `if` nests the
// reader exactly as a braced one does.
export default {
  id: "max-nesting-depth-three",
  category: "complexity",
  layer: "resilience",
  tier: "grit",
  severity: "warn",
  patternKey: "nesting-depth",
  title: "a statement container must not nest deeper than three layers",
  rationale:
    "every layer a reader descends is a condition or a loop they must hold in their head while they read the body, and the branches compound: four layers mean a reader tracks four independent conditions to know when the innermost line runs. a layer also multiplies the paths a test must cover, so a deep body is both the hardest code to read and the least tested. the shipped complexity rules count a function's total size and its branch total, so a deeply nested body inside a short function passes both while remaining the hard part of the file.",
  replacement:
    "return early when a condition fails, so the rest of the body stays at one layer. when the layers are a real state machine, extract the inner body into a named function or a dispatch table keyed on the subject, which turns the depth into a name.",
  detect({ ts, sourceFile, text }) {
    const limit = 3;
    const innate = new Set([
      ts.SyntaxKind.FunctionDeclaration,
      ts.SyntaxKind.FunctionExpression,
      ts.SyntaxKind.ArrowFunction,
      ts.SyntaxKind.MethodDeclaration,
      ts.SyntaxKind.Constructor,
      ts.SyntaxKind.GetAccessor,
      ts.SyntaxKind.SetAccessor,
      ts.SyntaxKind.ClassDeclaration,
      ts.SyntaxKind.ClassExpression,
    ]);
    const containers = new Set([
      ts.SyntaxKind.IfStatement,
      ts.SyntaxKind.ForStatement,
      ts.SyntaxKind.ForInStatement,
      ts.SyntaxKind.ForOfStatement,
      ts.SyntaxKind.WhileStatement,
      ts.SyntaxKind.DoStatement,
      ts.SyntaxKind.SwitchStatement,
      ts.SyntaxKind.TryStatement,
    ]);
    const blockOwners = new Set([
      ...containers,
      ts.SyntaxKind.CatchClause,
      ts.SyntaxKind.CaseClause,
    ]);
    const lines = text.split(/\r?\n/);
    const hits = [];
    const lineAt = (node) =>
      sourceFile.getLineAndCharacterOfPosition(node.getStart(sourceFile)).line +
      1;

    const walk = (node, depth, parentOwnsBlock, chainTail) => {
      if (innate.has(node.kind)) {
        ts.forEachChild(node, (child) => walk(child, 0, true, false));
        return;
      }
      const ownedBlock = ts.isBlock(node) && parentOwnsBlock;
      const isLayer =
        !ownedBlock && (containers.has(node.kind) || ts.isBlock(node));
      const layerDepth = isLayer && !chainTail ? depth + 1 : depth;
      if (isLayer && !chainTail && layerDepth > limit) {
        const line = lineAt(node);
        hits.push({
          line,
          column:
            sourceFile.getLineAndCharacterOfPosition(node.getStart(sourceFile))
              .character + 1,
          snippet: `layer ${layerDepth}, limit ${limit}: ${(lines[line - 1] ?? "").trim().slice(0, 80)}`,
        });
      }
      if (ts.isIfStatement(node)) {
        walk(node.expression, layerDepth, false, false);
        walk(node.thenStatement, layerDepth, true, false);
        const otherwise = node.elseStatement;
        if (otherwise !== undefined) {
          // an `else if` continues the same chain at the same layer, so only the
          // head of a chain is reported
          walk(
            otherwise,
            layerDepth,
            !ts.isIfStatement(otherwise),
            ts.isIfStatement(otherwise),
          );
        }
        return;
      }
      const owns = blockOwners.has(node.kind);
      ts.forEachChild(node, (child) => walk(child, layerDepth, owns, false));
    };

    walk(sourceFile, 0, false, false);
    return hits;
  },
};
