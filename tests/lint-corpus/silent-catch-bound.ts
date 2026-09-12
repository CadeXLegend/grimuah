export const f = (): void => {
  try {
    JSON.parse("{}");
  } catch (e) {
    void e;
  }
};
