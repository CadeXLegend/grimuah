import { dirname, resolve } from "node:path";

// whole-program cache: the graph is built once for the corpus the harness hands
// in, every later file reuses it
let cachedCorpus;
let cachedGraph;

// tarjan strongly connected components, a component of two or more files is a
// dependency cycle the surface firewall cannot see because both files can sit
// at the same dagOrder
const stronglyConnectedComponents = (graph) => {
  const discoveryIndex = new Map();
  const lowLink = new Map();
  const onStack = new Set();
  const pending = [];
  const components = [];
  let counter = 0;

  const connect = (nodeName) => {
    discoveryIndex.set(nodeName, counter);
    lowLink.set(nodeName, counter);
    counter += 1;
    pending.push(nodeName);
    onStack.add(nodeName);

    for (const edge of graph.get(nodeName) ?? []) {
      if (!graph.has(edge.target)) continue;
      if (!discoveryIndex.has(edge.target)) {
        connect(edge.target);
        lowLink.set(
          nodeName,
          Math.min(lowLink.get(nodeName), lowLink.get(edge.target)),
        );
      } else if (onStack.has(edge.target)) {
        lowLink.set(
          nodeName,
          Math.min(lowLink.get(nodeName), discoveryIndex.get(edge.target)),
        );
      }
    }

    if (lowLink.get(nodeName) === discoveryIndex.get(nodeName)) {
      const component = [];
      let popped = pending.pop();
      onStack.delete(popped);
      component.push(popped);
      while (popped !== nodeName) {
        popped = pending.pop();
        onStack.delete(popped);
        component.push(popped);
      }
      components.push(component);
    }
  };

  for (const nodeName of graph.keys()) {
    if (!discoveryIndex.has(nodeName)) connect(nodeName);
  }
  return components.filter((component) => component.length > 1);
};

const normalize = (pathValue) => pathValue.replaceAll("\\", "/");

// resolve against the filesystem root so the dot segments in a relative
// specifier are collapsed before the path is looked up
const toProjectPath = (fromRelPath, specifier) =>
  normalize(resolve("/", dirname(fromRelPath), specifier)).slice(1);

const buildGraph = (ts, corpus) => {
  const knownPaths = new Set(corpus.map((file) => file.relPath));
  const graph = new Map();
  for (const file of corpus) {
    const edges = [];
    for (const statement of file.sourceFile.statements) {
      if (
        !ts.isImportDeclaration(statement) ||
        !ts.isStringLiteral(statement.moduleSpecifier)
      )
        continue;
      const specifier = statement.moduleSpecifier.text;
      if (!specifier.startsWith(".")) continue;
      const basePath = toProjectPath(file.relPath, specifier);
      const target = [basePath, `${basePath}.ts`, `${basePath}/index.ts`].find(
        (candidatePath) => knownPaths.has(candidatePath),
      );
      if (target === undefined || target === file.relPath) continue;
      const line =
        file.sourceFile.getLineAndCharacterOfPosition(
          statement.getStart(file.sourceFile),
        ).line + 1;
      edges.push({ target, line, specifier });
    }
    graph.set(file.relPath, edges);
  }
  return graph;
};

export default {
  id: "no-import-cycles",
  category: "architecture",
  layer: "structural",
  tier: "prepass",
  severity: "error",
  patternKey: "import-cycle",
  title: "files must not form an import cycle, even within one surface",
  rationale:
    "the import firewall keeps imports flowing from deep surfaces to shallow ones, but two files at the same dagOrder can still import each other, and a cycle makes module initialisation order load-bearing, hides the true dependency direction, and lets a value read at module scope be undefined depending on which file the runtime reached first",
  replacement:
    "lift the shared symbols into a third module at or above the shallower of the two, or invert one direction with a callback or a parameter so the dependency points one way",
  detect({ ts, sourceFile, relPath, corpus }) {
    if (cachedCorpus !== corpus) {
      cachedCorpus = corpus;
      cachedGraph = buildGraph(ts, corpus);
    }
    const graph = cachedGraph;
    const components = stronglyConnectedComponents(graph);
    const componentOf = new Map();
    for (const component of components) {
      for (const componentNode of component)
        componentOf.set(componentNode, component);
    }
    const component = componentOf.get(relPath);
    if (component === undefined) return [];
    const cycleMembers = new Set(component);
    const closingEdge = (graph.get(relPath) ?? []).find((edge) =>
      cycleMembers.has(edge.target),
    );
    if (closingEdge === undefined) return [];
    return [
      {
        line: closingEdge.line,
        column: 1,
        snippet: `${closingEdge.specifier} -- imports back into a ${component.length} file cycle: ${component.toString()}`,
      },
    ];
  },
};
