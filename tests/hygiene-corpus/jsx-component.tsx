import { Panel } from "./panel";
import { Orphan } from "./orphan";

const Decoration = (): unknown => <hr />;
const Wrapper = (): unknown => <Panel.Content />;

let tuned = 1;
void tuned;
void Decoration;
void Wrapper;
