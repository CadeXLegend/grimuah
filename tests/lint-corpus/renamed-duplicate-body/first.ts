export const isMessageWithId = (value: unknown): boolean => {
  return typeof value === "object" && typeof value !== "undefined";
};
