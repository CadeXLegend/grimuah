export default {
  id: "config-declares-data-only",
  category: "architecture",
  layer: "structural",
  tier: "grit",
  severity: "warn",
  patternKey: "config-behaviour",
  title: "a .config.ts file must declare data only, never a function",
  rationale:
    "a config file sits at the lowest dagOrder of its surface, so an exported function there is callable from every layer above it with no firewall rule describing the dependency, the file stops being a declaration and becomes a module of behaviour that bypasses the surface that owns it, and because the function usually needs types or constants from the surface, it pulls the config into an import cycle the graph cannot express",
  replacement:
    "move the function into the surface's own module, or into lib when several surfaces need it, and keep the config file exporting enums and constants only",
  detect({ ts, sourceFile, relPath }) {
    if (!relPath.endsWith(".config.ts")) return [];
    const hits = [];
    const record = (node) => {
      const position = sourceFile.getLineAndCharacterOfPosition(
        node.getStart(sourceFile),
      );
      hits.push({
        line: position.line + 1,
        column: position.character + 1,
        snippet: `${node.getText(sourceFile).replace(/\s+/g, " ").slice(0, 110)} -- config files declare data, this is behaviour`,
      });
    };
    for (const statement of sourceFile.statements) {
      const isExported = statement.modifiers?.some(
        (modifier) => modifier.kind === ts.SyntaxKind.ExportKeyword,
      );
      if (!isExported) continue;
      if (ts.isFunctionDeclaration(statement)) {
        record(statement);
        continue;
      }
      if (ts.isVariableStatement(statement)) {
        for (const declaration of statement.declarationList.declarations) {
          const initializer = declaration.initializer;
          const isFunction =
            initializer !== undefined &&
            (ts.isArrowFunction(initializer) ||
              ts.isFunctionExpression(initializer));
          if (isFunction) record(declaration);
        }
      }
    }
    return hits;
  },
};
