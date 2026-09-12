export const f = (): void => {
  try {
    JSON.parse("{}");
  } catch ({ message }) {
    void message;
  }
};
