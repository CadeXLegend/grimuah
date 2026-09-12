export const f = (x: number): number => {
  let total = x;
  switch (total) {
    case 1:
      break;
    default:
      total = 0;
  }
  return total;
};
// an em-dash: —
export const g = (): string => "a — b";
