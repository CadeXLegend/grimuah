// the surface's own values. a config is where an enum belongs, so this file is here for the
// rule that reads it from the other side: the consumer beside it retypes two of these
// values. the corpus is linted with every layer on, so nothing here is a banned construct

export enum MusicSubcommandName {
  Play = "play",
  Skip = "skip",
}
