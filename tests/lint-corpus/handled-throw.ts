export const f = (): void => {
  try {
    JSON.parse("{}");
  } catch (e) {
    throw new Error(String(e));
  }
};
