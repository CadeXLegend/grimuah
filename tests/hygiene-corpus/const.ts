declare const cond: boolean;
let moduleNoInit;
moduleNoInit = 5;
void moduleNoInit;

let inIf;
if (cond) {
  inIf = 5;
}
void inIf;

let inTry;
try {
  inTry = 5;
} catch {
  void 0;
}
void inTry;

let inFn;
const setInFn = (): void => {
  inFn = 5;
};
void setInFn;
void inFn;

let moduleLevel;
const setModule = (): void => {
  moduleLevel = 5;
};
void setModule;
void moduleLevel;

const assignedOnce = 1;
void assignedOnce;
