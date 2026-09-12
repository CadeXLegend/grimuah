// the parameter cap: five parameters is one past the limit, four is the limit,
// and a destructured parameter stays one slot although it binds two names. the
// corpus is linted with every layer on, so nothing here is a banned construct

export function fiveParameters(
  first: string,
  second: string,
  third: string,
  fourth: string,
  fifth: string,
): string {
  return first + second + third + fourth + fifth;
}

export function fourParameters(first: string, second: string, third: string, fourth: string): string {
  return first + second + third + fourth;
}

export function fourPatterns(
  { left, right }: Record<string, string>,
  { up, down }: Record<string, string>,
  { near, far }: Record<string, string>,
  { high, low }: Record<string, string>,
): string {
  return `${left}${right}${up}${down}${near}${far}${high}${low}`;
}
