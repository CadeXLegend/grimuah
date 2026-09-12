import { existsSync, readFileSync } from "node:fs";
import { dirname, relative } from "node:path";

// the firewall's canImport consults allowedImports only when the importing
// surface is at the same or a shallower dagOrder than the target. an import
// from a deeper surface to a shallower one returns true unconditionally, so an
// entry naming a shallower surface is never read
const CONFIG_FILE = "architecture.config.json";

let cachedRoot;
let cachedConfig;

const findProjectRoot = (fromPath) => {
  let current = dirname(fromPath);
  for (;;) {
    if (existsSync(`${current}/${CONFIG_FILE}`)) return current;
    const parent = dirname(current);
    if (parent === current) return undefined;
    current = parent;
  }
};

const loadConfig = (fromPath) => {
  const root = findProjectRoot(fromPath);
  if (root === undefined)
    return { root: undefined, surfaces: [], dagOrderByName: new Map() };
  if (cachedRoot === root) return cachedConfig;
  const parsed = JSON.parse(readFileSync(`${root}/${CONFIG_FILE}`, "utf8"));
  const surfaces = (parsed.surfaces ?? []).filter(
    (surface) => (surface.allowedImports ?? []).length > 0,
  );
  const dagOrderByName = new Map();
  for (const surface of parsed.surfaces ?? [])
    dagOrderByName.set(surface.name, surface.dagOrder);
  cachedRoot = root;
  cachedConfig = { root, surfaces, dagOrderByName };
  return cachedConfig;
};

// longest configured surface path that prefixes the project-relative path
const surfaceOf = (config, projectRelPath) => {
  const parts = projectRelPath.split("/");
  for (let depth = parts.length - 1; depth >= 1; depth -= 1) {
    const prefix = parts.slice(0, depth).toString().replaceAll(",", "/");
    const match = config.surfaces.find((surface) => surface.path === prefix);
    if (match !== undefined) return match;
  }
  return undefined;
};

export default {
  id: "no-redundant-allowed-import",
  category: "architecture",
  layer: "structural",
  tier: "prepass",
  severity: "warn",
  patternKey: "redundant-allowed-import",
  title:
    "an allowedImports entry naming a shallower surface is never consulted and must be removed",
  rationale:
    "the import firewall already permits every import from a deeper surface to a shallower one, so an allowlist entry naming a shallower surface is dead configuration that the checker never reads, a reader cannot tell which entries are load bearing and which merely restate the dag order, and the whole allowlist stops adding up to anything once its entries are indistinguishable from the default",
  replacement:
    "delete the entry and keep only the grants that permit a real backward edge, a deeper surface listed for a shallower one. in grimuah this finding belongs on architecture.config.json rather than on a source file",
  detect({ ts, filePath, relPath, corpus }) {
    const config = loadConfig(filePath);
    if (config.root === undefined) return [];
    const projectRelPath = relative(config.root, filePath).replaceAll(
      "\\",
      "/",
    );
    const surface = surfaceOf(config, projectRelPath);
    if (surface === undefined) return [];
    const dagOrder = config.dagOrderByName.get(surface.name);
    const redundant = (surface.allowedImports ?? []).filter((allowedName) => {
      const allowedOrder = config.dagOrderByName.get(allowedName);
      return allowedOrder !== undefined && allowedOrder < dagOrder;
    });
    if (redundant.length === 0) return [];
    // one report per surface, anchored at the surface's first file so a 45 file
    // surface does not repeat the same config finding 45 times
    const surfaceFiles = corpus
      .map((file) => relative(config.root, file.filePath).replaceAll("\\", "/"))
      .filter((candidatePath) => candidatePath.startsWith(`${surface.path}/`))
      .sort();
    if (surfaceFiles[0] !== projectRelPath) return [];
    return redundant.map((allowedName) => ({
      line: 1,
      column: 1,
      snippet: `surface '${surface.name}' (dagOrder ${dagOrder}) grants '${allowedName}' (dagOrder ${config.dagOrderByName.get(allowedName)}) -- the dag already permits this, the entry is never read`,
    }));
  },
};
