# Reading script for a generated voice corpus

Written to be *generated*, not performed: text for a server-side model to read
in one consistent narrator voice, so the result can train a small local TTS
voice that ships with the application.

**This is training material, not liturgy.** None of it is spoken in a session.
The library's own text is already rendered (1.76 h of usable speech, 1,361
clips); this script exists to cover what that corpus does not.

## Size

70 blocks, **6,777 spoken words**, 1,362 distinct — roughly
**47 minutes at 143 words per minute** (the rate the first take came out at) or
**62 minutes at a slower 110**. That is squarely inside fine-tuning range for a
small local voice, which wants somewhere between thirty minutes and two hours.

638 of those distinct words do not appear anywhere in the library's own
narration, so this is additional coverage rather than a second helping of what
is already rendered.

Each block is sized for one generation. Generate them one at a time from the
same persona rather than concatenating — a single long request is where a
server-side model is most likely to skip, summarise or drift.

## What it targets

Measured against `library/segments/*.gws`, which speak 14,146 words, 1,726 of
them distinct:

- **Numbers are thin and one is missing.** "fifty" appears zero times;
  "thirteen" and "eighteen" five times each; "seven" twelve. The app counts
  constantly — one to ten on the way in, ten to one, twelve to one and three to
  one on the way out — so numbers carry more weight here than their frequency
  suggests.
- **Focus level names** are spoken through `[[destinationPublished]]` rather
  than in any `say` line, so they are underrepresented in what was rendered.
- **Register coverage**: the library is almost entirely long, flowing,
  legato instruction. Short imperatives and declarative affirmations are rarer,
  and a voice trained only on the former will not land the latter.

What it deliberately does *not* chase is general English breadth. The 173
common letter-trigrams absent from the library are almost all Latin and Greek
scientific morphology — "ism", "ology", "epi", "dro". This voice will never say
them.

## How to generate it

The single thing that decides whether this is usable: **one voice across every
clip**. Generate one block, keep the take whose voice you want, save it as a
persona, and generate everything else from that persona. Without that the
corpus is several narrators averaged together, and the trained voice is mush.

Then, before training:

1. **Verify the transcript against the audio.** A generation that skips,
   repeats or embellishes a line is poison for TTS training, because the model
   learns text it never heard. Run it through ASR and either correct the
   transcript to what was actually said or discard the clip.
2. **Reject anything with music, reverb tail or a second voice.** Room and
   accompaniment get learned as part of the timbre.
3. **Normalise loudness** across clips, and keep the native sample rate rather
   than upsampling.

## Style

    spoken word guided meditation, single calm male narrator, warm low register,
    slow measured pace, intimate close-mic, dry and unprocessed, hypnotherapy
    narration, even unhurried breath, no music

## Negative

    music, instrumental, melody, singing, sung vocals, harmony, chorus, autotune,
    drums, percussion, beat, bassline, synth pad, ambient pad, drone, strings,
    piano, guitar, reverb, echo, delay, room tone, background noise, rain, wind,
    ocean, waves, crowd, applause, sound effects, multiple voices, duet, female
    vocal, child voice, accent shift, energetic, upbeat, dramatic, urgent,
    shouting, whisper, breathy ASMR, vocal fry, laughing, humming, spoken over
    music

---

## Block 1 — settling, long legato

Let the weight of your body arrive where it rests. There is nothing to reach
for now, and nothing that needs deciding. Notice the surface beneath you and
allow it to hold the whole of that weight, without your help. The shoulders
release first, then the jaw, then the small muscles around the eyes that have
been working all day without being asked. Let the breath find its own depth.
You are not managing it. You are only noticing that it continues, as it has
continued through every hour you never thought about it. Warmth gathers where
the hands rest. The room recedes, not because it has gone, but because your
attention has stopped spending itself there. Whatever you carried into this
hour can wait outside it. It will still be there, and you will meet it rested.
Let the edges of the body soften until you are less aware of where you end and
the air begins.

## Block 2 — counting up, the ten-point system

Now, gently, and with no effort at all, we will count. One. Feeling relaxed and
comfortable. Two. Moving further from the physical, further from concern.
Three. Four. The body heavier, the mind clearer. Five. More relaxed than you
have been all day. Six. Seven. Deeper still, and entirely safe. Eight. Nine.
Almost there now, unhurried. Ten. You have arrived. Mind awake, body asleep.
Rest here. Nothing is required of you at this level except to notice it.
Eleven. Twelve. Thirteen. Fourteen. Fifteen. Sixteen. Seventeen. Eighteen.
Nineteen. Twenty. Twenty-five. Thirty. Thirty-five. Forty. Forty-five. Fifty.
One hundred. The first breath. The second breath. The third. The fourth and the
fifth, each one longer than the one before it.

## Block 3 — counting down, the returns

We will return now, as I count from ten down to one. Ten. Nine. Beginning to
come back toward the physical. Eight. Seven. Six. Your senses waking, becoming
more and more aware. Five. Four. Three. Two. One. Wide awake, both physically
and mentally, feeling better in every way. Now again, from twelve. Twelve.
Eleven. Ten. Nine. Eight. Seven. Six. Five. Four. Three. Two. One. Wake up.
Open your eyes. Stretch your arms and legs. Breathe deeply. And once more, the
short return, from three. Three. Two. Your five physical senses operating
clearly, cleanly, sharply and beautifully. One. Completely refreshed. That
completes the exercise.

## Block 4 — the levels, proper nouns

Focus One is ordinary waking consciousness, the state you are in when you begin.
Focus Three is a signpost, a Hemi-Sync state in which brain and mind grow more
coherent, more synchronised and balanced. Focus Ten. Mind awake, body asleep.
Focus Eleven, the access channel. Focus Twelve, expanded awareness. Focus
Fifteen, no time, no space. Focus Eighteen, the heart level. Focus Twenty-One,
the bridge. Focus Twenty-Two. Focus Twenty-Three, where new arrivals wait.
Focus Twenty-Four, Twenty-Five and Twenty-Six, the belief system territories.
Focus Twenty-Seven, the park, the place of your own. Focus Thirty-Four and
Thirty-Five, the gathering. Focus Forty-Two. Focus Forty-Nine, the sea of
I-There clusters.

## Block 5 — energy, breath, tuning

Begin the resonant tuning. Inhale slowly through the nose, drawing fresh energy
in from all around you, and direct it upward into the head. Hold it there a
moment. Then exhale through the mouth, lips pursed as though blowing out a
candle, and let anything stale or used leave with the breath. Again. The
vibration begins in the chest and rises. Feel it in the throat, in the roof of
the mouth, behind the eyes. Now the energy conversion box. Place into it every
concern you do not need for the next hour. Close it. Set it aside. It will be
exactly where you left it. Now the balloon, rising from the crown, tethered and
patient, gathering the light that surrounds you.

## Block 6 — affirmation, declarative

I am more than my physical body. Because I am more than physical matter, I can
perceive that which is greater than the physical world. I deeply desire to
expand, to experience, to know, to understand, to control and to use such
greater energies and energy systems as may be beneficial and constructive to me
and to those who follow me. I also deeply desire the help and cooperation, the
assistance and understanding of those individuals whose wisdom, development and
experience are equal to or greater than my own. I ask their guidance and
protection from any influence or any source that might provide me with less
than my stated desires.

## Block 7 — short imperatives, staccato

Notice. Allow. Release. Let it go. Breathe in. Hold. Breathe out. Again. Rest
now. Softer. Slower. Deeper. Good. Stay with that. Come back to the breath.
Feel the hands. Feel the feet. Nothing to do. Nowhere to be. Just here. Just
now. Open. Wider. Wider still. Hold it. And release. Let the shoulders drop.
Unclench the jaw. Soften the eyes. Yes. That is it. Stay.

## Block 8 — perceptual instruction, second person

Whatever you perceive here, receive it without deciding in advance what it
ought to be. You may notice colour, or movement, or a sense of presence that
you would struggle to describe afterwards. You may notice nothing at all, and
that is not a failure. The instruction is only to observe, and to keep
observing after the first impression has passed, because what arrives second is
often more interesting than what arrived first. Confirm nothing you have been
told merely because you were told it. Amend it where your own experience
differs. Reject it where it does not fit. Your observations remain yours.

## Block 9 — long flowing description, legato

Ahead of you the light changes, not suddenly but the way an afternoon changes
into an evening, so gradually that you cannot name the moment it happened. The
ground here is neither warm nor cold. There is a great deal of space and none of
it is empty. If you move, you move without effort and without covering
distance, arriving at the place you intended by having intended it. Others may
be present. Some will be familiar in a way you cannot immediately account for.
There is no hurry, and there is no schedule that you are behind. You have been
here before, in the hour just before waking, and forgotten it on the way out.

## Block 10 — awkward phonetics and edge cases

Thirty-three thousand. Nineteen ninety-seven. The eighth of August. Two
thousand and twenty-six. First, second, third, fourth, fifth, sixth, seventh,
eighth, ninth, tenth. Twelve point five. Point four hertz. One hundred hertz.
Four point zero. One point five. Zero point two five. Half. Quarter. Whole.
Nonphysical. Non-physical. Preexisting. Reemerge. Cooperation. Coordination.
Simultaneously. Unequivocally. Rhythm. Rhythmic. Sixths. Twelfths. Strengths.
Clothes. Months. Asked. Texts. World's. Earth's.

## Block 11 — settling, the hands and arms

Bring your attention to the hands. Not to move them, only to find them. Notice
the temperature of the palms, and whether one is warmer than the other. Notice
the place where the fingers touch, and the small spaces where they do not.
Follow the warmth up through the wrists, where the skin is thin and the pulse
is easy to find if you look for it. The forearms grow heavy. The elbows give up
their last small tension. The upper arms soften against your sides, and the
shoulders, which have been holding a shape all day without being asked, let
that shape go. There is nothing here that needs carrying. Nothing here that
needs lifting. Let the arms belong to the surface beneath them rather than to
you. If a finger twitches, that is the body releasing something it had been
holding, and it needs no correction. Let it happen and let it pass. The hands
grow heavier still, and warmer, until the boundary between the skin and the air
becomes difficult to locate precisely. You are not asleep. You are only setting
down something you did not know you were carrying.

## Block 12 — settling, the face and head

Now the face. This is where we hold what we do not say. Let the jaw unhinge
very slightly, so the upper and lower teeth are no longer touching. Let the
tongue rest low and wide in the mouth rather than pressed against the palate.
Soften the muscles around the eyes, the small ones at the outer corners, the
ones that have been narrowing against light or against thought since you woke.
Let the eyebrows drift apart and downward. Let the forehead become broad and
smooth. The scalp releases. Behind the ears, along the base of the skull, a
line of tension that has been there so long you had stopped registering it
begins to let go, and as it does the head grows heavier and rests more fully.
The breath moves through the nose without effort. The face is doing nothing.
Nobody is watching. There is nothing to arrange.

## Block 13 — settling, the spine and legs

Follow the spine down from the base of the skull, one vertebra at a time, and
let each one settle a fraction lower than the one above it. Between the
shoulder blades. Behind the heart. The middle of the back, where the ribs
attach. The lower back, which carries the most and complains the least. The
pelvis broadens and softens. The hips release outward. The thighs grow heavy
and warm, then the knees, then the calves. The ankles loosen. The feet fall
open. Notice the heels against the surface, and the arches which touch nothing
at all. Every part of you that can be given over to gravity has now been given
over to it. What remains is the breath, and the small steady work of the heart,
neither of which requires your attention, though you may keep it there if you
would like the company.

## Block 14 — breath, the long instruction

Let the breath lengthen without forcing it. Draw the air in slowly through the
nose, and let it reach lower than usual, into the base of the ribs, so the
belly rises before the chest does. Pause there a moment, not holding, only
resting at the top. Then let it out through the mouth, slowly, twice as long as
the breath in, until the lungs are comfortably empty and the shoulders have
dropped another fraction. Again. In through the nose, filling from the bottom.
A pause at the top. And out, unhurried, longer than you took to fill. A third
time. And notice, as you do it, that the mind has already begun to follow the
rhythm rather than to comment on it. That following is the whole technique.
There is nothing more sophisticated waiting further in.

## Block 15 — breath, the short instruction

Breathe in. Two. Three. Four. Hold. Two. Three. Four. Out. Two. Three. Four.
Five. Six. And again. In, two, three, four. Hold, two, three, four. Out, two,
three, four, five, six. Once more, and this time let the exhale be the part you
pay attention to. In. Hold. Out, slowly, all the way to the bottom. Rest at the
bottom for a moment before the next breath arrives on its own. It will arrive.
You do not have to send for it.

## Block 16 — counting, one to ten with variation

We will count upward now, and with each number you will find yourself a little
further from the concerns of the room. One. Settling. Two. The body growing
comfortable and heavy. Three. Attention turning inward. Four. Quieter now.
Five. Halfway, and already further than you expected. Six. The room has gone
somewhere behind you. Seven. Deeper. Eight. Deeper still, and entirely under
your own control. Nine. Almost. And ten. Here. Mind awake, body asleep. Take a
moment to notice what this is like, because it will be easier to find again
once you know what you are looking for.

## Block 17 — counting, longer ranges and ordinals

One, two, three, four, five, six, seven, eight, nine, ten. Eleven, twelve,
thirteen, fourteen, fifteen, sixteen, seventeen, eighteen, nineteen, twenty.
Twenty-one, twenty-two, twenty-three, twenty-four, twenty-five, twenty-six,
twenty-seven. Thirty, thirty-four, thirty-five. Forty, forty-two, forty-nine.
Fifty. Sixty. Seventy. Eighty. Ninety. One hundred. The first time. The second
time. The third, the fourth, the fifth. The sixth breath, the seventh, the
eighth, the ninth, the tenth. Twelfth. Fifteenth. Twentieth. Twenty-first.
Thirtieth. Fortieth. Fiftieth. Hundredth.

## Block 18 — counting, the return, warm

It is time to come back. I will count from ten down to one, and as I do, you
will return gently and completely to ordinary waking awareness, bringing with
you whatever you found here. Ten. Beginning to return. Nine. Aware of the room
again, of the air in it. Eight. Aware of the surface beneath you. Seven. The
body reassembling itself under your attention. Six. The hands. Five. The feet.
Four. The breath deepening on its own. Three. Alert now, and comfortable. Two.
Almost fully back. One. Eyes open when you are ready. Wide awake, refreshed,
and feeling better in every way.

## Block 19 — counting, the return, brisk

Coming back now. Five. Four. Three. Two. One. Awake. Or from three, if the
journey was short. Three. Two. One. Open your eyes. Or from twelve, if it was
long. Twelve, eleven, ten, nine, eight, seven, six, five, four, three, two,
one. Wake up. Stretch. Breathe deeply. That completes the exercise.

## Block 20 — place, the wide field

There is a field here, though field is not quite the word, because it has no
edges you could walk to and the light does not come from any direction you
could point at. The ground is even. The air is neither warm nor cool, and it
does not move. If you look toward the horizon there is a horizon, and if you
stop looking for it the horizon stops being necessary. Nothing here is
threatening. Nothing here is in a hurry. You may stay as long as you like, and
the staying will not cost you anything you will miss later. Some people find a
structure here. Some find water. Some find another person who seems to have
been expecting them. Some find nothing at all on the first visit and a great
deal on the fourth. All of those are ordinary.

## Block 21 — place, the room that is not a room

Somewhere just behind the eyes there is a room you have never furnished, and it
is furnished anyway. The proportions are agreeable. There is a chair, or
something that serves as one. There is light without a lamp. When you arrive
here you will notice that you already know your way around, in the manner of a
house you lived in as a child and have not visited since. Objects here have a
tendency to be what you need rather than what you expected. If you look for a
door there will be a door. If you look for a window the view through it will be
worth the looking. Take your time. This place is not going anywhere, and neither,
for the moment, are you.

## Block 22 — place, water

There is water ahead of you, and the sound it makes arrives before the sight of
it does. A long slow draw, a pause, and a release, over and over, at almost
exactly the rhythm your own breathing has settled into. Perhaps that is a
coincidence. Perhaps the breathing arranged itself to match. Walk down to the
edge if you would like to. The surface is dark and unhurried. Nothing is
beneath it that wishes you harm. You may sit here for a while and let the sound
do the work that instruction has been doing until now. There is nothing further
to understand. The tide is not a metaphor for anything. It is only very old,
and very patient, and entirely uninterested in whatever you were worrying about
an hour ago.

## Block 23 — observation, the honest instruction

Whatever happens in the next few minutes, receive it without deciding in
advance what it ought to have been. You may see colour. You may hear something
that is not a sound. You may feel the unmistakable presence of somebody who is
not there, and afterwards be unable to describe them in a way that satisfies
you. Or you may notice nothing whatsoever, and lie here for twenty minutes
being mildly bored, and that is not a failure and it is not evidence of
anything. Observation is the instruction. Keep observing past the first
impression, because the second and third are usually more interesting and
almost always more specific. Do not confirm what you have been told merely
because you were told it. Amend it where your own experience differs from it.
Reject it where it plainly does not fit. What you notice belongs to you.

## Block 24 — observation, the sceptic's note

It is reasonable to be sceptical here, and scepticism costs you nothing. You do
not have to believe anything at all for this to be worth an hour. The breathing
is real. The relaxation is measurable. The state you reach is one your own
nervous system produces without assistance from any theory about what it means.
If you would prefer to treat everything else as imagination, do that, and you
will still arrive at the same place by the same route. Imagination is not a
lesser faculty. It is the one that builds every room you have ever planned
before you built it. Use it without apology and without conclusion.

## Block 25 — energy and warmth

Feel the warmth gathering at the centre of the chest, and let it spread outward
at whatever speed it chooses. Across the shoulders. Down the arms to the
fingertips, which may begin to tingle very slightly. Up through the throat and
into the face. Down through the belly, the hips, the legs, all the way to the
soles of the feet. The whole body warm now, and lightly charged, the way the
air is charged before weather arrives. Draw a breath in and let the warmth
brighten with it. Let it out and let the warmth settle. Again. Brighter. And
settle. You are not making this happen. You are noticing something that is
already happening and giving it room.

## Block 26 — the affirmation register, original

I am more than the body I can measure. Because that is so, I can perceive more
than the body can measure. I intend to expand, to experience, to understand,
and to make use of whatever proves genuinely useful, and to set aside whatever
does not. I ask for the assistance of anything wiser than myself that is
willing to offer it, and I decline the attention of anything that is not. I
will keep my own counsel about what I find here. I will not mistake a strong
impression for a settled fact, and I will not dismiss a quiet one merely
because it was quiet.

## Block 27 — short imperatives, first set

Settle. Soften. Let go. Breathe. Slower. Slower still. Good. Stay there. Notice
the hands. Notice the feet. Notice the weight. Release the jaw. Release the
shoulders. Release the belly. Yes. That. Hold nothing. Chase nothing. Let it
come. Let it go. Again. Rest. Wait. Watch. Allow. Receive. Continue. Return.
Open your eyes.

## Block 28 — short imperatives, second set

Sit up if you need to. Lie back. Adjust once and then stop adjusting. Close the
eyes. Take one deep breath. Take another. Let the third one be ordinary. Count
with me. Follow the count. Do not hurry it. Do not test it. Find the level.
Stay at the level. Look around. Ask a question. Wait for an answer. Notice what
arrives. Do not grade it. Come back when I call you. Come back now.

## Block 29 — long flowing description, evening

The light here changes the way an afternoon becomes an evening, which is to say
gradually and without any moment you could name afterwards as the one where it
happened. Colour drains out of the middle distance first and stays longest near
the ground. Sounds carry further. The air develops that particular quality it
has in late summer, when the heat has gone out of it but the warmth has not,
and everything smells faintly of the day it has just finished being. If you
have somewhere to be, you are already there. If you have someone to meet, they
are on their way and are not late. There is a long, slow, unremarkable
contentment available here that has nothing to do with achievement and cannot
be earned, only accepted, and it is offered without conditions for as long as
you are willing to remain still enough to receive it.

## Block 30 — long flowing description, morning

Before the light there is a greyness that is not yet colour, and in it every
edge is approximate. Then the first real light arrives, low and horizontal,
and everything it touches acquires a long shadow that will shorten all morning
until it disappears entirely and then begins again on the other side. Birds
start before the light does. They have always known something we have to be
reminded of, which is that the day is not an obligation but a recurrence, and
that it will happen whether or not you are ready, and that being ready was
never the requirement. Take a breath here. The air is cold and clean and it
will wake the parts of you that the counting put to sleep. There is work ahead
and it will be manageable. There are people ahead and most of them mean well.

## Block 31 — questions, interrogative prosody

Where is the breath right now? Is it high in the chest, or low in the belly? Is
it faster than it was a minute ago, or slower? What is the temperature of the
air as it enters, and is it different as it leaves? Can you find the exact
moment the inhale becomes the exhale? Is there a pause there, or does one become
the other without an edge? What is the heaviest part of you at this moment?
What is the lightest? If you had to point to where you are, where would you
point? Is that where you would have pointed an hour ago? What would you like
from this hour? Are you willing to receive it if it arrives in a form you did
not ask for? And if nothing arrives at all, will that be acceptable?

## Block 32 — negation and constraint

You do not need to try. You do not need to concentrate. Nothing here is a test,
and there is no result that would count as failing it. Do not force the breath.
Do not chase the image. Do not correct the mind when it wanders; simply notice
that it has, and come back, and expect to do that many more times before the
hour is out. That is not a fault in your practice, that is the practice. Do not
grade what you find. Do not conclude too early. Do not tell yourself that
nothing is happening merely because nothing dramatic is happening. And do not
stay if you would rather not. You can open your eyes at any moment and be
entirely awake, entirely yourself, with nothing left behind.

## Block 33 — comparatives and conditionals

If the room is too warm, it will be harder to stay awake, and easier to drift.
If it is too cold, the body will keep asking for your attention and will keep
getting it. Somewhere between the two is better than either. If you have eaten
recently you may find this heavier going than usual; if you have not eaten at
all, hunger will do the same job from the other direction. Later in the day is
generally easier than early. Lying down is deeper than sitting, and sitting is
safer if you would rather not fall asleep. A darker room is more forgiving than
a bright one. Headphones are better than speakers, and closed headphones are
better than open ones, though either will do. Louder is not better. Quieter is
usually better than you expect.

## Block 34 — lists and enumeration

There are several things worth having to hand before you begin. Something to
write with. Something to write on. A blanket, because the body cools when it
stops moving. A pillow under the knees if you are lying on your back, or
between them if you are on your side. Water, for afterwards. A door that closes.
A phone that is somewhere else. There are also several things you do not need,
and it is worth naming them so you stop looking for them: incense, candles,
particular clothing, a particular posture, a particular time of day, a
particular belief about what any of this is, and any equipment beyond what you
already own.

## Block 35 — dates, figures, measurement

On the fourteenth of March, nineteen seventy-four. Between nineteen seventy-two
and nineteen eighty-one. The third of November, two thousand and six. The
twenty-second of June. Twelve point five hertz. Four point zero hertz. One point
five hertz. Zero point four hertz. One hundred hertz. Forty-eight thousand.
Twenty-four thousand. Twenty-two thousand and fifty. Sixteen bits. Two channels.
Ninety-five per cent. Three quarters. Two thirds. One half. A third of a second.
Ninety minutes. Forty-five minutes. Twenty minutes. Seven and a half. Nought
point one one. Two hundred and fifty. Fifteen hundred. Ten thousand.

## Block 36 — phonetic drill, consonant clusters

Strengths. Sixths. Twelfths. Months. Clothes. Asked. Texts. Depths. Widths.
Glimpsed. Prompts. Sculpts. Twelfth month. World's end. Earth's surface. Both
things. Fifth sixth seventh. Crisp thin threads. Blackthorn. Handcrafted.
Streetlight. Whirlwind. Bookshelf. Fistful. Kindness. Landscape. Sandstorm.
Thoughtful. Breathless. Truthfully. Rhythmically. Simultaneously. Unequivocally.
Preexisting. Reemerge. Cooperation. Coordination. Nonphysical. Non-physical.
Semiconscious. Hypnagogic. Hemispheric. Synchronised. Resonant. Coherent.

## Block 37 — phonetic drill, vowels and diphthongs

Beat, bit, bait, bet, bat, bought, boat, boot, but, bite, bout, boy. Feel the
difference between them without hurrying. Ear, air, are, oar, ore, our.
Peculiar. Familiar. Idea. Theatre. Fluid. Ruin. Poem. Chaos. Neon. Aeon. Quiet.
Riot. Diet. Trial. Loyal. Royal. Layer. Player. Mayor. Slower. Lower. Fewer.
Newer. Truer. Doer. Sewer. Viewer.

## Block 38 — proper nouns and technical terms

Focus One. Focus Three. Focus Ten. Focus Eleven. Focus Twelve. Focus Fifteen.
Focus Eighteen. Focus Twenty-One. Focus Twenty-Two. Focus Twenty-Three. Focus
Twenty-Four. Focus Twenty-Five. Focus Twenty-Six. Focus Twenty-Seven. Focus
Thirty-Four. Focus Thirty-Five. Focus Forty-Two. Focus Forty-Nine. Hemi-Sync.
Hemispheric synchronisation. Binaural. Binaural beat. Carrier frequency. Delta.
Theta. Alpha. Beta. Gamma. Resonant tuning. Energy conversion box. Affirmation.
Rebal. The access channel. Expanded awareness. Belief system territories. The
park. The gathering. I-There. The sea of clusters. Waking consciousness.

## Block 39 — instruction with embedded pause cues

Take a moment now. And another. Let the silence be part of the instruction
rather than a gap in it. When I stop speaking, I have not gone away, and you
have not been left behind. The next thing I say will arrive when it is useful
and not before. In the meantime there is nothing to fill. Practise being spoken
to and then not spoken to, without the second one feeling like an absence.
Rest. And rest. And rest again. When you notice you have been waiting for me,
stop waiting. That is the whole of it.

## Block 40 — reassurance and safety

Nothing that happens here can harm you. You are lying in a room, breathing,
with your own nervous system doing something it is entirely capable of doing.
If at any point you would rather stop, stop. Open your eyes, sit up, and the
state releases immediately and completely, the way waking from a dream does.
You will not be stuck. You will not be taken anywhere against your will. You
cannot be lost. If something arrives that you do not want, decline it, and it
will go, because your attention is the only thing giving it a place to stand.
Nothing here requires courage. It only requires an hour and a closed door.

## Block 41 — the induction, told slowly

We begin the way every session begins, which is by doing less. Let the eyes
close, if they have not already. Let the breath find a rhythm you are not
supervising. And then let the body report itself to you, part by part, without
your changing anything about what it reports. The feet, which have carried you
today. The legs, which did not complain. The hips, the base of the spine, the
long muscles either side of it that have been quietly working since you got out
of bed. The belly, rising and falling. The chest. The collarbones. The throat,
which has said a great many things today and would like to stop. The face. The
scalp. And then the whole of it at once, all reporting the same thing, which is
that it is here, and it is safe, and it is willing to be still for a while.

## Block 42 — the induction, told briskly

Eyes closed. Breath easy. Feet heavy, legs heavy, hips loose, back long, belly
soft, chest open, shoulders down, arms heavy, hands warm, jaw slack, eyes
still, forehead smooth. One breath in. One breath out. Counting from one to ten.
One, two, three, four, five, six, seven, eight, nine, ten. There. That is the
whole induction. It works as well quickly as it does slowly, once you know the
route.

## Block 43 — a longer narrative

There was a period, some years ago, when I could not do this at all. I would
lie down and last about ninety seconds before some urgent and entirely
imaginary piece of business would arrive and demand attention, and I would get
up and attend to it, and it would turn out not to have been urgent. This went
on for months. What eventually changed was not that the interruptions stopped,
but that I stopped treating them as instructions. They still arrive. They are
still just as convincing. I simply no longer stand up. If you are in that
period now, it is worth knowing that it is a period and not a verdict, and that
nobody who does this easily began by doing it easily.

## Block 44 — a second narrative

The first time anything unmistakable happened, it was so unremarkable that I
nearly missed it. No lights, no voices, no sense of leaving anywhere. Only a
very precise awareness of the room behind me, including a detail I could not
have seen from where I was lying, and which turned out afterwards to be correct.
I have thought about that for a long time and I still do not know what to make
of it, and I have decided that not knowing what to make of it is an acceptable
place to leave it. You may collect several of these. They do not add up to a
theory. They accumulate into something more like a habit of attention.

## Block 45 — closing, warm

We are near the end now. Whatever you found here is yours to keep, and you do
not have to justify it to anyone, including yourself. If you found nothing,
that is also yours, and it costs you nothing to come back tomorrow. Take one
more breath at this depth. Let it be the longest one. And now begin the return.
Feel the surface beneath you again. Feel the air in the room. Hear whatever
there is to hear beyond this voice. Move the fingers. Move the toes. Roll the
shoulders once. And when you are ready, and not before, let the eyes open.

## Block 46 — closing, brisk

Coming back. Five, four, three, two, one. Eyes open. Sit up slowly. Drink some
water. Write down anything you want to remember before it goes, because it will
go, and faster than you expect. That is the exercise.

## Block 47 — the journal instruction

Write it down badly rather than not at all. Do not compose. Do not explain. Put
the plain fact of what you noticed on the page in the order you noticed it, and
resist the urge to make it into a story while it is still warm. Colour, if there
was colour. Position, if you had one. Anything that had the quality of arriving
rather than of being produced. Note the time. Note how long it took to settle.
Note whether you were tired. Six months of these is worth more than any single
remarkable evening, because six months of them will show you a pattern you
could not have predicted, and a single evening will only show you an evening.

## Block 48 — miscellany, everyday vocabulary

Kitchen. Doorway. Window. Staircase. Garden. Pavement. Bicycle. Umbrella.
Newspaper. Telephone. Envelope. Cupboard. Blanket. Mattress. Curtain. Ceiling.
Carpet. Radiator. Kettle. Teaspoon. Saucer. Bookshelf. Photograph. Wristwatch.
Shoelace. Pocket. Jacket. Scarf. Glove. Button. Zip. Key. Lock. Handle. Hinge.
Threshold. Corridor. Landing. Attic. Cellar. Chimney. Rooftop. Skyline.

## Block 49 — miscellany, weather and landscape

Rain on a flat roof. Wind through a hedge. Frost on the inside of a window.
Fog that does not lift until eleven. A long dry August. Thunder some distance
off, arriving late after the light. Snow that settles on the branches and not
on the road. A river in spate. A canal that has not moved in a hundred years.
Chalk. Granite. Sandstone. Clay. Heather. Bracken. Gorse. Hawthorn. Beech.
Rowan. Larch. Yew.

## Block 50 — the plain ending

That is all. There is nothing further to do, nothing to remember, and nothing
you are now required to believe. Come back when you would like to. The route
does not close. Thank you for the hour.

## Block 51 — verbs, present tense

You settle. You soften. You breathe. You notice. You release. You allow. You
observe. You wait. You return. You wake. The body relaxes. The mind quietens.
The breath deepens. The shoulders drop. The jaw releases. The warmth spreads.
The attention gathers. The room recedes. The count begins. The level arrives.
Something changes. Something remains. Nothing insists.

## Block 52 — verbs, past and future

You settled quickly last time and slowly the time before. You noticed something
and then lost it. You waited, and waited, and eventually stopped waiting, and
that was when it came. Tomorrow you will lie down again and it will be
different, and the day after that it will be different again, and after a month
of that you will begin to see the shape of it. You will forget most of what
happens. You will remember the wrong parts. You will write down what you can
and be grateful later that you did.

## Block 53 — sensory, touch and temperature

Cool air at the nostrils. Warm air leaving the mouth. The slight roughness of a
blanket against the back of the hand. A cold patch where the foot has escaped
the cover. The weight of a pillow under the skull. The pressure of the heels.
The place where the shirt gathers under the shoulder blade. The pulse at the
wrist, faint, then obvious once you have found it, then faint again once you
stop looking. Heat in the palms. A single point of cold somewhere along the
spine that arrives and then goes.

## Block 54 — sensory, sound

A car three streets away. A pipe expanding somewhere in the building. Wind
finding the corner of a window. Your own swallow, unreasonably loud. A bird
that has decided the hour is wrong and is singing anyway. The hum a room makes
when nothing in it is running. And underneath all of it, if you go looking, a
faint high tone that is not in the room at all, and has been there your whole
life, and that most people never notice because nobody ever told them to check.

## Block 55 — abstract nouns

Patience. Attention. Curiosity. Stillness. Willingness. Restraint. Precision.
Honesty. Doubt. Certainty. Expectation. Disappointment. Familiarity. Novelty.
Discipline. Habit. Rhythm. Repetition. Consistency. Duration. Interval.
Boundary. Threshold. Transition. Arrival. Departure. Recognition. Recall.
Perception. Interpretation. Judgement. Suspension of judgement.

## Block 56 — explanation register, technical but calm

The effect works on a simple principle. Two slightly different frequencies are
presented, one to each ear, and the brain resolves the difference as a third
tone that is not physically present in either signal. If the left ear receives
one hundred hertz and the right receives one hundred and four, the difference
is four hertz, which is a rate the auditory system can follow but no speaker can
produce. Over some minutes, activity in both hemispheres tends to converge
toward that rate. That convergence is the whole mechanism, and it requires
headphones, because the effect exists in the difference and speakers destroy the
difference by mixing the signals in the air before they reach you.

## Block 57 — explanation register, practical

Sessions run between twenty and forty-five minutes. The first ten are induction
and the last five are return, which leaves the middle for whatever the session
is actually for. Nothing is gained by lengthening the middle before the ends
are reliable. Do the short ones until the short ones are boring. Boring is the
correct outcome of the early stage and most people quit before reaching it,
because they were promised something else. What comes after boring is worth
the wait, but only arrives on the far side of it.

## Block 58 — reported speech

He said that it took him a year before anything at all happened, and then two
years before anything happened reliably. She said it was immediate and she has
never understood why other people find it difficult. Someone else told me they
gave up three times and came back three times, and that the fourth attempt was
the one that held, and that nothing about the fourth attempt was different
except that they had stopped expecting it to work. All three of them are
describing the same thing. None of them can tell you how to do it.

## Block 59 — emphasis and contrast

Not harder. Easier. Not faster. Slower. Not more attention. Less interference.
Not concentration, which is effortful, but attention, which is not. Not trying
to reach a state, but allowing one that is already available. Not making the
mind blank, which is impossible, but letting it be busy without following it.
Not silence. Quiet. There is a difference, and the difference is the whole
practice.

## Block 60 — the second person, warm and direct

You have been at this for a while now, and you have probably not given yourself
much credit for it. It is unglamorous work with no visible progress and no one
to notice it. There is no belt, no certificate, nobody to tell you that you
have moved up. What there is instead is a slow accumulation of hours in which
you were quiet on purpose, and the effect of those hours is real and cumulative
and almost entirely invisible from outside. Keep going. It compounds.

## Block 61 — hesitation, natural speech rhythm

So. Let us begin again, from the top, and this time a little slower. Now. Where
were we. Yes. The breath. Right. Take one, and let it be deeper than the last
one. And then, when you are ready, another. Good. Now, the body. Start
wherever you like. It does not matter where you start. Really, it does not.
Anywhere. Fine. The feet, then. Good. The feet.

## Block 62 — counting with distraction handling

One. If the mind has wandered already, that is normal, come back. Two. Three.
It will wander again between four and five, and again around seven. Four. Five.
There it goes. Come back. Six. Seven. And again. Come back. Eight. Nine. You
are not doing this badly. Everyone does this. Ten. Here we are anyway, which is
the point: the wandering did not prevent the arriving.

## Block 63 — the long hold

I am going to leave you here for a while. There will be no voice for some
minutes. Use them however you like. Explore, or rest, or do nothing at all.
When I return I will call you back gently, and you will hear me even if you
have drifted, and if you have fallen asleep entirely that is fine and you needed
it. Until then, the room is yours.

## Block 64 — the recall

Coming back to my voice now. Wherever you went, bring it with you. Whatever you
saw, hold onto the first detail rather than the whole scene, because the first
detail is the one that will survive. If there was nothing, bring back the
nothing; it is still information. Beginning to return.

## Block 65 — troubleshooting

If you fall asleep every time, sit up instead of lying down, and try earlier in
the evening. If you cannot stop thinking, stop trying to; let the thinking run
and pay attention to the breath underneath it. If your nose blocks on one side,
that is normal and it will swap in about forty minutes. If your hands feel
enormous or your body feels the wrong shape, that is a good sign and not a
problem. If you feel a jolt just as you settle, that is a hypnic twitch, it is
harmless, and it means you were on the edge of exactly the right place.

## Block 66 — commitment, plain

Twenty minutes. Four times a week. For six weeks. That is the entire
commitment, and it is smaller than almost anything else you have agreed to this
year. Put it in the calendar like a dentist's appointment, because the ones
that are not in the calendar do not happen. At the end of six weeks, decide
whether to continue, using evidence rather than enthusiasm.

## Block 67 — numbers in context

Session one of six. Session two of six. Session three. Session four. The fifth
of six. And the sixth. Track one, track two, track three. Take one. Take two.
Take three. Version one point zero. Version two point one. Chapter nine. Page
one hundred and forty-two. Room three hundred and seven. Nineteen minutes and
twenty-six seconds. Twenty-five minutes and forty-two seconds. Thirty-seven
minutes and thirty-two seconds. Forty-one minutes exactly.

## Block 68 — closing, formal

This concludes the session. Return now to full physical waking awareness,
carrying with you whatever proved useful and leaving behind whatever did not.
You will find that you remember more of this in an hour than you do at this
moment, and more again tomorrow. Be unhurried in getting up. Drink something.
Do not drive immediately. Thank you.

## Block 69 — closing, informal

Right. That is us finished. Have a stretch. Get some water. Write the notes
before you make the tea, not after, because after never happens. See you
tomorrow.

## Block 70 — the last one

Rest now. There is nothing else. No count, no instruction, no destination. Just
the breath, and the weight of you, and the quiet, for as long as you would like
it. Goodnight.
