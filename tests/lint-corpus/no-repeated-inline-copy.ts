// the same sentence written twice inside one module, which is the smallest form of the
// copy defect and the one the cross-file rule cannot see: it needs three files before it
// reports at all. the corpus is linted with every layer on, so nothing here is a banned
// construct, and no second file takes part in this verdict

export async function announceNothingPlaying(voice: Voice): Promise<void> {
  await voice.reply("Nothing is queued up right now.");
}

export async function skipToNextTrack(voice: Voice): Promise<void> {
  await voice.reply("Nothing is queued up right now.");
}
