# Tasks — Phase 00

Objective:

Fully understand how the application works using Docker Compose.

---

# Task 1 — Run the application

Run:

`docker compose up`


Verify:

- frontend is accessible
- backend responds
- database is connected

---

# Task 2 — Explore containers

List containers:


`docker ps`


**Questions**:

- How many containers are there?
- Which images are being used?

---

# Task 3 — Explore networking

Enter the backend container:


`docker exec -it <backend-container> sh`


Try to connect to postgres using:


`ping postgres`


**Question**:

Why does the hostname `postgres` work?

---

# Task 4 — Explore environment variables

View the backend's environment variables:


docker exec <backend-container> env


**Question**:

How does the backend receive the database connection URI?

---

# Task 5 — Explore volumes

List volumes:


`docker volume ls`


Inspect:


`docker volume inspect postgres_data`


**Question**:

Where is the data actually stored?

---

# Task 6 — Restart containers

Stop containers:


`docker compose down`


Start them again:


`docker compose up`


**Question**:

- Does the data still exist?

- Why?

---

# Task 7 — Understand architecture

Draw the application flow:


browser → frontend → backend → database


**Questions**:

- Who calls whom?
- Which services need to communicate?
- Which services need persistence?