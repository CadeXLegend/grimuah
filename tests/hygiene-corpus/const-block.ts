declare const cond: boolean;
let withInit = 1;
if (cond) {
  withInit = 2;
}
void withInit;

let withInitFn = 1;
const setIt = (): void => {
  withInitFn = 2;
};
void setIt;
void withInitFn;

let plainInit = 1;
void plainInit;

let twoAssigns;
twoAssigns = 1;
twoAssigns = 2;
void twoAssigns;

let oneAssignNested;
if (cond) {
  oneAssignNested = 1;
  twoAssigns = 3;
}
void oneAssignNested;
