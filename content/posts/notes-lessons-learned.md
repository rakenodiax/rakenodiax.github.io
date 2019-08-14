---
title: "Notes Lessons Learned"
date: 2019-07-27T17:28:54+02:00
draft: true
featuredImg: ""
tags: 
  - tag
---

Using ts-jest with parcel requires configuring Jest to understand the `~` alias:

```
moduleNameMapper: {
  "~(.*)$": "<rootDir>/src/$1",
},
```
