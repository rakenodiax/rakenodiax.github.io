---
title: "Strongly Typed Google Analytics Events with Typescript"
date: 2019-08-26T18:38:22+02:00
tags:
  - typescript
  - analytics
  - demo
  - events
categories:
  - programming
  - mealspotter
draft: false
---

For [MealSpotter](https://www.mealspotter.de), we use [Google Analytics Events](https://support.google.com/analytics/answer/1033068?hl=en) to help us better understand how well Deals are performing, and bring that insight to our restaurant partners. Ensuring that our analytics data are clean helps us to work with our partners to bring even better deals to our users.

This post will go into how to define an Events schema using Typescript, using a simplified example of the method we use at MealSpotter.

Each event contains the following data:

1. Category
2. Action
3. Label (optional)
4. Value (optional)

While the label is optional, having the additional specificity really comes in handy. If you want to assign a monetary value to a particular event, then that field can be used as well.

## The Code

This example uses a similar pattern to Redux with Typescript: You take a broad type and narrow it down to specific events, which are created via helper functions.

### Setup

Let's say we want to use events to track how often a user clicks on boxes of various colors. We have a simple component for a Box:

{{<highlight tsx "linenos=table,linenostart=0" >}}
/* src/box.tsx */
import React from 'react';
// type Color = 'red' | 'green' | 'blue';
import Color from './color';

type Props = {
  color: Color;
  onClick(): void;
};

export const Box: React.FC<Props> = ({ color, onClick }) => (
  <div style={{
    backgroundColor: color,
    height: '10rem',
    width: '30vw',
    margin: '8px',
    display: 'inline-block',
    color: 'white',
    textAlign: 'center',
  }}
  onClick={() => onClick()}
  >
    <p style={{
      verticalAlign: 'middle',
    }}>
      Click me!
    </p>
  </div>
);
{{< / highlight >}}

And we render a box for each color in our App:

{{<highlight tsx "linenos=table,linenostart=0" >}}
/* src/app.tsx */
import React from 'react';
import Box from './box';
import Color from './color';

const App: React.FC = () => {
  const colors: Color[] = ['red', 'green', 'blue'];

  function handleClick(color: Color): void {
    console.log(`color ${color} clicked`);
  }

  const boxes = colors.map((color) => (
    <Box color={color}
         key={color}
         onClick={() => handleClick(color)}
    />
  ));

  return (
    <div>
      { boxes }
    </div>
  )
};

export default App;
{{< / highlight >}}

### Implementing Events

Now that we have the components set up, we can move onto the events. Assuming we have a simple facade to interface with GA:

{{<highlight tsx "linenos=table,linenostart=0" >}}
/* src/analytics-facade/i-analytics-facade.ts */
export interface IAnalyticsEvent {
  category: string;
  action: string;
  label?: string;
  value?: number;
}

export interface IAnalyticsFacade<T extends IAnalyticsEvent> {
  sendEvent(event: T): void;
}
{{< / highlight >}}

Since we're currently only tracking one "action" &mdash; clicking a box &mdash; our event type is pretty simple:

{{<highlight tsx "linenos=table,linenostart=0" >}}
/* src/events.ts */
import { IAnalyticsEvent } from "./analytics-facade/i-analytics-facade";
import Color from "./color";

export type BoxClickEvent = IAnalyticsEvent & {
  category: 'box',
  action: 'click',
  label: Color,
};
{{< / highlight >}}

On line 4 we're taking the `IAnalyticsEvent` and *narrowing* it to specific types for `category`, `action`, and `label`. Now let's write a helper function to create new events from colors:

{{<highlight tsx "linenos=table,linenostart=8" >}}
/* src/events.ts */
// ...
export const boxClick = (color: Color): BoxClickEvent => ({
  category: 'box',
  action: 'click',
  label: color,
});
{{< / highlight >}}

Writing a simple class which can handle only our events ensures that only events which comply with our event schema are sent to GA:

{{<highlight tsx "linenos=table,linenostart=0" >}}
/* src/analytics-facade/analytics-facade.ts */
import { IAnalyticsFacade } from "./i-analytics-facade";
import { BoxClickEvent } from "../events";

export class AnalyticsFacade implements IAnalyticsFacade<BoxClickEvent> {
  public sendEvent(event: BoxClickEvent): void {
    // In reality, this would be a call to GA
    console.debug(event);
  }
}
{{< / highlight >}}

### Adding another event

Clicks are great, but normally there are multiple events which need to be tracked. Let's add another event for when a box is displayed (an impression):

{{<highlight tsx "linenos=table,linenostart=14" >}}
/* src/events.ts */
// ...
export type BoxImpressionEvent = IAnalyticsEvent & {
  category: 'box',
  action: 'impression',
  label: Color,
};

export const boxImpression = (color: Color): BoxImpressionEvent => ({
  category: 'box',
  action: 'impression',
  label: color,
});
{{< / highlight >}}

We can wrap up all of our event types into a union type to use with our `AnalyticsFacade`:

{{<highlight tsx "linenos=table,linenostart=26" >}}
/* src/events.ts */
// ...
export type AppEvent = BoxClickEvent | BoxImpressionEvent;
{{< / highlight >}}

{{<highlight tsx "linenos=table,hl_lines=[3],linenostart=2" >}}
/* src/analytics-facade/analytics-facade.ts */
// ...
export class AnalyticsFacade implements IAnalyticsFacade<AppEvent> {
  public sendEvent(event: AppEvent): void {
    console.debug(event);
  }
}
{{< / highlight >}}

### Going beyond

As your events grow, it's useful to split the event type definitions and event creators into their own modules. Even further down the line, defining common properties as an `enum` of strings, or consolidating common collections into their own intermediate types, can make the code more clear. A contrived example with these two events could look something like this:

{{<highlight tsx "linenos=table,linenostart=0" >}}
/* src/events/types.ts */
import { IAnalyticsEvent } from "../analytics-facade/i-analytics-facade";
import Color from "../color";

// Categories
export enum EventCategory {
  Box = 'box',
}

// Actions
export enum BoxAction {
  Click = 'click',
  Impression = 'impression',
}

type EventAction = BoxAction;

// Labels
type BoxLabel = Color;

type EventLabel = BoxLabel;

// Events
/**
 * The base event which can only be of a predefined `category`, `action`, and `label`
 * the `label` narrowing may not fit all use cases
 */
export type AppEvent = IAnalyticsEvent & {
  category: EventCategory,
  action: EventAction,
  label: EventLabel,
}

/**
 * Events for the `Box` category
 */
type BoxEvent = AppEvent & {
  category: EventCategory.Box,
  action: BoxAction,
  label: BoxLabel,
};

export type BoxClickEvent = BoxEvent & {
  action: BoxAction.Click
};

export type BoxImpressionEvent = BoxEvent & {
  action: BoxAction.Impression,
};
{{< / highlight >}}

{{<highlight tsx "linenos=table,linenostart=0" >}}
/* src/events/creators.ts */
import { BoxClickEvent, BoxImpressionEvent, EventCategory, BoxAction } from "./types";
import Color from "../color";

export const boxClick = (color: Color): BoxClickEvent => ({
  category: EventCategory.Box,
  action: BoxAction.Click,
  label: color,
});

export const boxImpression = (color: Color): BoxImpressionEvent => ({
  category: EventCategory.Box,
  action: BoxAction.Impression,
  label: color,
});
{{< / highlight >}}

## Conclusion

Ensuring that GA data is structured and conforming to a specific schema can be business critical, and can save having to painstakingly fix or throw out valuable data. Leveraging Typescript to ensure that code cannot send incorrect data is another line of defense which I can recommend.

Feedback, questions, and comments are always welcome! You can find me [on Twitter](https://twitter.com/rakenodiax). Happy coding!
