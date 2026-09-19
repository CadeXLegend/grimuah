export const isChannelWithId = (value: unknown): boolean =>
{
  return typeof value === "object" && typeof value !== "undefined";
};
