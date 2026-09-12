export const f = (): void => {
  try {
    JSON.parse("{}");
  } catch {
    return void 0;
  }
};
