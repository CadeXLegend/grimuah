const { orphan } = { orphan: 1 };
const { used } = { other: 1 };
void used;
const { renamed: alias } = { renamed: 1 };
const [head] = [1];
const {
  nested: { deep },
} = { nested: { deep: 1 } };
function take({ param }: { param: number }): void {
  void param;
}
const { fromObject } = getThing();
