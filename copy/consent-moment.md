# Consent moment: every word a person sees

Draft for Jose's review. Nothing here ships until he approves it.

How to read this file: each `## key` heading is one piece of text on screen, and the line
under it is exactly what the person reads. Lines that start with `>` are notes for Jose and
never reach the screen. Words in braces, like `{host}`, are filled in at the moment: the
site that blocked the agent, the cap, and so on. The app reads this file directly, so an
edit here is an edit on screen, with no second copy to keep in sync.

The moment appears once: the first time the agent is turned away by a site while the
person is in Solo. Whatever they choose, the choice afterwards lives on the tier dial, and
sirven does not ask again on later blocks.

> Design rules applied: Solo and Neighborly buttons carry equal visual weight on every
> screen, nothing is preselected, there is no countdown, and "Stay in Solo" is always one
> tap away. Each screen holds one idea.

## Screen 1: the block

## consent.block.eyebrow
Your agent was turned away

## consent.block.title
{host} blocked your agent.

## consent.block.body
Some sites refuse agents. In Solo, sirven stops here and tells you, rather than finding another way in.

## consent.block.stay
Stay in Solo

## consent.block.learn
What would Neighborly change?

## Screen 2: what Neighborly means

## consent.means.title
Neighborly is a trade between members.

## consent.means.lend.label
You lend

## consent.means.lend.body
Up to {cap} a month of your connection, to other members' agents.

## consent.means.get.label
You get

## consent.means.get.body
Their connections, when a site turns yours away.

## consent.means.agent.label
Your agent

## consent.means.agent.body
Takes routine steps on listed sites without asking first. It still asks before anything that spends money.

> Note for Jose: the scope says Neighborly brings "more agent autonomy" but does not say
> how much. "Routine steps on listed sites, still asks before spending" is my draft of
> that line. Please confirm or replace it; the dial uses the same wording.

## consent.means.linked
Lending and autonomy move together. That is on purpose: the more you share, the more your agent can do.

## Screen 3: where the traffic goes

## consent.list.title
Only to sites on the public list.

## consent.list.body
A person reviews every site before it is added, and writes down why. The list is public, so you always know what your Mac might carry.

## consent.list.count.none
The list is empty right now. Nothing is carried until a site is reviewed and added.

## consent.list.count.one
1 site is on the list today.

## consent.list.count.many
{count} sites are on the list today.

## Screen 4: what your Mac carries

## consent.carry.title
What your Mac carries for others.

## consent.carry.yes
Page requests from other members' agents, including signed-in sessions, to sites on the list.

## consent.carry.no
Nothing to sites off the list. Nothing once you reach {cap} this month.

## consent.carry.who
Only for members whose identity sirven has verified.

## consent.carry.private
Your Mac sees which site and how much. It does not see the pages.

> Note for Jose: "does not see the pages" is only true if the peer-routing design keeps the
> connection encrypted end to end between the member's agent and the site, so the carrying
> Mac relays it without reading it. Threads 02 and 03 own that design. Hold this line until
> they confirm it, or cut it.

## Screen 5: how we prove it is bounded

## consent.proof.title
How you know it stays bounded.

## consent.proof.cap
Your Mac counts every byte, carried and sent, against the same {cap}. At the cap it stops.

## consent.proof.both
Both sides record each transfer, so neither can quietly inflate the other's count.

## consent.proof.signed
Every request is signed by the member who sent it, so it can be traced, and that member removed.

## consent.proof.meter
You can watch the meter any time, and leave Neighborly in one step.

## Screen 6: the choice

## consent.choose.title
Your call.

## consent.choose.body
You can change this on the dial whenever you like.

## consent.choose.join
Turn on Neighborly

## consent.choose.stay
Stay in Solo

## consent.back
Back

## consent.next
Next

## consent.close
Close

## After the choice

## consent.done.neighborly
You are in Neighborly. The meter starts counting now.

## consent.done.solo
You are staying in Solo. Nothing is shared.

## When Neighborly is not open yet

## consent.closed.title
Neighborly is not open yet.

## consent.closed.body
It opens once request signing and site review both work end to end. Until then, you stay in Solo.

## consent.closed.ack
Understood

> Note for Jose: the first ship gate says no peer routing until attestation and the
> site-allowlist review workflow both work end to end. Until the runtime reports that both
> are live, the last screen shows this text in place of "Turn on Neighborly", so the moment
> can be reviewed and tested without anyone being able to switch peer routing on.
