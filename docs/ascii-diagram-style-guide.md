# ASCII Diagram Style Guide

How to draw high-level architecture and user-flow diagrams in plain text using Unicode box-drawing characters. Every diagram is built from three parts: **boxes**, **connections**, and (optionally) **special shapes** such as users and databases.

## 1. The basic example

Two boxes, one connection. Everything else in this guide is a variation of this.

```text
┌─────────────┐         ┌─────────────┐
│ Backend API │────────▶│  Frontend   │
└─────────────┘         └─────────────┘
```

## 2. Box styles

Pick one style per diagram, or use styles to mean something (see section 6).

```text
Light                Heavy                Double
┌─────────────┐      ┏━━━━━━━━━━━━━┓      ╔═════════════╗
│ Backend API │      ┃ Backend API ┃      ║ Backend API ║
└─────────────┘      ┗━━━━━━━━━━━━━┛      ╚═════════════╝

Rounded              Dotted (rounded)     Dotted (dot corners)
╭─────────────╮      ╭┈┈┈┈┈┈┈┈┈┈┈┈┈╮      ·┈┈┈┈┈┈┈┈┈┈┈┈┈·
│ Backend API │      ┊ Backend API ┊      ┊ Backend API ┊
╰─────────────╯      ╰┈┈┈┈┈┈┈┈┈┈┈┈┈╯      ·┈┈┈┈┈┈┈┈┈┈┈┈┈·

Block                Block (thin inset)
▛▀▀▀▀▀▀▀▀▀▀▀▀▀▜      ▗▄▄▄▄▄▄▄▄▄▄▄▄▄▖
▌ Backend API ▐      ▐ Backend API ▌
▙▄▄▄▄▄▄▄▄▄▄▄▄▄▟      ▝▀▀▀▀▀▀▀▀▀▀▀▀▀▘

Database (cylinder)
 .---------.
(           )
|`---------'|
|  Postgres |
 `---------'
```

Use the database box only for data stores (Postgres, ClickHouse, Redis, S3). It is 13 characters wide, so indent it by one space to center it under a 15-character box.

## 3. Line styles

```text
Solid    ─────────────
Heavy    ━━━━━━━━━━━━━
Double   ═════════════
Dashed   ╌╌╌╌╌╌╌╌╌╌╌╌╌
Dotted   ┈┈┈┈┈┈┈┈┈┈┈┈┈
```

## 4. Connections

A connection has four properties:

| Property    | Values                                          |
|-------------|-------------------------------------------------|
| from / to   | the two boxes it joins                          |
| line style  | solid, heavy, double, dashed, dotted            |
| arrow       | none, forward, backward, both                   |
| orientation | horizontal (left/right) or vertical (top/bottom) |

### 4.1 Characters per line style

| Style  | Horizontal | Vertical | Box edge tee (down / up) |
|--------|------------|----------|--------------------------|
| Solid  | `─`        | `│`      | `┬` / `┴`                |
| Heavy  | `━`        | `┃`      | `┳` / `┻`                |
| Double | `═`        | `║`      | `╦` / `╩`                |
| Dashed | `╌`        | `╎`      | `┬` / `┴`                |
| Dotted | `┈`        | `┊`      | `┬` / `┴`                |

Arrowheads: `▶` right, `◀` left, `▼` down, `▲` up.

The tee belongs to the **box border**, so it matches the box style, not the line style. Dotted and block boxes have no tee characters: start the line on the row below the box instead.

### 4.2 Horizontal direction

```text
Right    ────────────▶
Left     ◀────────────
Both     ◀───────────▶
None     ─────────────
```

Works the same with every line style:

```text
Heavy    ━━━━━━━━━━━━▶    ◀━━━━━━━━━━━━    ◀━━━━━━━━━━━▶
Double   ════════════▶    ◀════════════    ◀═══════════▶
Dashed   ╌╌╌╌╌╌╌╌╌╌╌╌▶    ◀╌╌╌╌╌╌╌╌╌╌╌╌    ◀╌╌╌╌╌╌╌╌╌╌╌▶
Dotted   ┈┈┈┈┈┈┈┈┈┈┈┈▶    ◀┈┈┈┈┈┈┈┈┈┈┈┈    ◀┈┈┈┈┈┈┈┈┈┈┈▶
```

### 4.3 Vertical direction

```text
Down   Up     Both   None
 │      ▲      ▲      │
 │      │      │      │
 ▼      │      ▼      │
```

Full vertical example, with a tee on the source box:

```text
┌─────────────┐
│  Frontend   │
└──────┬──────┘
       │
       ▼
┌─────────────┐
│ Backend API │
└─────────────┘
```

### 4.4 Labels

Put the label inside the line (horizontal) or beside it (vertical).

```text
┌─────────────┐         ┌─────────────┐
│  Frontend   │──HTTPS─▶│ Backend API │
└─────────────┘         └─────────────┘

┌─────────────┐
│  Frontend   │
└──────┬──────┘
       │ HTTPS
       ▼
┌─────────────┐
│ Backend API │
└─────────────┘
```

## 5. Special shapes

### 5.1 User (person)

A user is a small figure, never a box. Put the label underneath. Head, body and legs share one center column; connect lines to that column.

```text
Single     Group of users
 (O)        (O)  (O)  (O)
--|--      --|----|----|--
 / \        / \  / \  / \
User            Users
```

### 5.2 Database (cylinder)

Same shape as the database box style in section 2. Connect to the center of the top edge.

```text
 .---------.
(           )
|`---------'|
|  Postgres |
 `---------'
```

### 5.3 Devices

Use these for clients and hosts. The server is 15 characters wide, like the boxes. The laptop's screen is 13 wide and its keyboard widens to 17 at the bottom for perspective, so outdent it by 1 space to center it in a column. The phone is 5 wide, so indent it by 5 spaces.

```text
Phone      Laptop             Server
╭───╮       ┌───────────┐     ┌─────────────┐
│   │       │           │     │ o  ──────── │
│ o │       │  Laptop   │     ├─────────────┤
╰───╯       └───────────┘     │ o  ──────── │
Phone      ╱═════════════╲    ├─────────────┤
          └───────────────┘   │ o  Server   │
                              └─────────────┘
```

### 5.4 Scaling (1..N replicas)

Use a **stacked box** when a single service runs as several identical copies. Put the replica count under the stack.

```text
┌─────────────┐         ┌─────────────┐
│  Frontend   │────────▶│ Backend API ├┐
└─────────────┘         └┬────────────┘├┐
                         └┬────────────┘│
                          └─────────────┘
                            1..N pods
```

Use a **deployment container** when the diagram is about the infrastructure itself (Kubernetes Deployment, autoscaling group). Draw it as a dashed box titled on its top edge, with one small box per pod.

```text
                        ┌╌ Deployment: backend ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┐
┌─────────────┐         ╎ ┌───────┐ ┌───────┐       ┌───────┐ ╎
│  Frontend   │────────▶╎ │ pod 1 │ │ pod 2 │  ...  │ pod N │ ╎
└─────────────┘         ╎ └───────┘ └───────┘       └───────┘ ╎
                        └╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┘
```

### 5.5 Putting it together: user flow

```text
      (O)
     --|--
      / \
     User
       │ HTTPS
       ▼
┌─────────────┐
│  Frontend   │
└──────┬──────┘
       │ REST
       ▼
┌─────────────┐
│ Backend API │
└──────┬──────┘
       │ SQL
       ▼
  .---------.
 (           )
 |`---------'|
 |  Postgres |
  `---------'
```

## 6. Suggested meaning (optional convention)

| Element          | Meaning                                  |
|------------------|------------------------------------------|
| `─────▶` solid   | synchronous call (HTTP, gRPC)            |
| `━━━━━▶` heavy   | critical / hot path                      |
| `═════▶` double  | high-volume data stream                  |
| `╌╌╌╌╌▶` dashed  | asynchronous event or message queue      |
| `┈┈┈┈┈▶` dotted  | optional / fallback path                 |
| `◀────▶` both    | bidirectional (WebSocket, streaming)     |
| Light box        | internal service                         |
| Heavy box        | core component                           |
| Double box       | system boundary / gateway                |
| Dotted box       | external or third-party system           |

## 7. Drawing rules

1. Render in a monospace font inside a fenced code block.
2. Give every box in a row the same width; center the label with at least one space of padding.
3. Arrowheads touch the box edge: no gap between `▶` and `│`.
4. Keep at least 8 characters between horizontally connected boxes so labels fit.
5. Center vertical lines on the box: the tee, line, and arrowhead share one column.

`▶ ◀ ▲ ▼` render double-width in some fonts (mostly CJK locales). If alignment must hold everywhere, fall back to ASCII `> < ^ v`.
