export const f = (): void => {
  try {
    JSON.parse("{}");
  } catch {
    throw 1;
  }
};
