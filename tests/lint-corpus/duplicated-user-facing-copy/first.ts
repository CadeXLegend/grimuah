// one sentence written into three files. the rule counts distinct files rather than
// occurrences, so two files alone would report nothing: this fixture needs three, and
// the second sentence below stays in two of them on purpose. the corpus is linted with
// every layer on, so nothing here is a banned construct

export const NothingPlaying = "Nothing is playing right now.";

export const OnlyTwoFiles = "Only two files write this one.";
