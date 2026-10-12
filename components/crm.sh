# shellcheck shell=bash
# crm: Twenty, an open source customer relationship manager, self-hosted with Docker Compose.
#
# optional. core never reads this file: only sirven add crm and sirven remove crm do, through
# lib/components.sh. add copies a Docker Compose file into the owner's folder, where it is
# theirs to edit, fills in a dotenv the owner controls with the two secrets Twenty needs, and
# starts Twenty on this machine only.
#
# the steps follow Twenty's own self-hosting guide, option 2, manual steps:
#   https://docs.twenty.com/developers/self-host/capabilities/docker-compose
# read on 2026-10-11, at Twenty release v2.46.0. docs/COMPONENTS.md has the details.

CRM_TWENTY_VERSION="v2.46.0"
CRM_ADDRESS="http://localhost:3000"
CRM_MINIMUM_DOCKER_COMPOSE="2.0.0"

component_crm_summary() {
  printf 'Twenty, a self-hosted customer relationship manager, run with Docker Compose'
}

# Twenty's guide asks for Docker with Compose 2 or newer. openssl makes the secrets, and curl
# asks Twenty whether it is up.
component_crm_preflight() {
  local strict="$1" version
  preflight_commands "$strict" docker openssl curl
  command -v docker >/dev/null 2>&1 || return 0
  version="$(first_version "$(docker compose version 2>&1 | head -n 1)")"
  if [ -z "$version" ]; then
    _preflight_problem "$strict" "docker compose, the Compose plugin, did not answer"
  elif ! version_at_least "$version" "$CRM_MINIMUM_DOCKER_COMPOSE"; then
    _preflight_problem "$strict" "docker compose $version is older than $CRM_MINIMUM_DOCKER_COMPOSE"
  else
    printf 'preflight: ok docker compose %s\n' "$version" >&2
  fi
}

# the file add copies. written from Twenty's docker-compose.yml at release v2.46.0
# (packages/twenty-docker in github.com/twentyhq/twenty), with the image pinned, the port bound
# to this machine only, and the secrets required instead of defaulted.
crm_compose_file() {
  cat <<'END'
# Twenty, a customer relationship manager, copied here by sirven add crm.
#
# this file is yours: edit it as you like. sirven add crm never overwrites it, and
# sirven remove crm keeps it when you have changed it.
#
# written from Twenty's own Docker Compose file at release v2.46.0
# (packages/twenty-docker/docker-compose.yml in github.com/twentyhq/twenty), following
# https://docs.twenty.com/developers/self-host/capabilities/docker-compose
# what differs from it:
#   - the Twenty image is pinned to v2.46.0. to upgrade, read Twenty's upgrade guide first.
#   - port 3000 answers on this machine only (127.0.0.1). to reach Twenty from elsewhere, put it
#     behind your transport, and set SERVER_URL in the dotenv to the address you use.
#   - ENCRYPTION_KEY and PG_DATABASE_PASSWORD have no defaults: compose stops if the dotenv
#     lacks them. losing ENCRYPTION_KEY loses every secret Twenty stored.
name: sirven-crm

services:
  server:
    image: twentycrm/twenty:v2.46.0
    volumes:
      - server-local-data:/app/packages/twenty-server/.local-storage
    ports:
      - "127.0.0.1:3000:3000"
    environment:
      NODE_PORT: 3000
      PG_DATABASE_URL: postgres://postgres:${PG_DATABASE_PASSWORD:?the dotenv needs PG_DATABASE_PASSWORD}@db:5432/default
      SERVER_URL: ${SERVER_URL:-http://localhost:3000}
      REDIS_URL: redis://redis:6379
      STORAGE_TYPE: local
      ENCRYPTION_KEY: ${ENCRYPTION_KEY:?the dotenv needs ENCRYPTION_KEY}
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy
    healthcheck:
      test: curl --fail http://localhost:3000/healthz
      interval: 5s
      timeout: 5s
      retries: 20
    restart: always

  worker:
    image: twentycrm/twenty:v2.46.0
    volumes:
      - server-local-data:/app/packages/twenty-server/.local-storage
    command: ["yarn", "worker:prod"]
    environment:
      PG_DATABASE_URL: postgres://postgres:${PG_DATABASE_PASSWORD:?the dotenv needs PG_DATABASE_PASSWORD}@db:5432/default
      SERVER_URL: ${SERVER_URL:-http://localhost:3000}
      REDIS_URL: redis://redis:6379
      DISABLE_DB_MIGRATIONS: "true"
      DISABLE_CRON_JOBS_REGISTRATION: "true"
      STORAGE_TYPE: local
      ENCRYPTION_KEY: ${ENCRYPTION_KEY:?the dotenv needs ENCRYPTION_KEY}
    depends_on:
      db:
        condition: service_healthy
      server:
        condition: service_healthy
    restart: always

  db:
    image: postgres:16
    volumes:
      - db-data:/var/lib/postgresql/data
    environment:
      POSTGRES_DB: default
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: ${PG_DATABASE_PASSWORD:?the dotenv needs PG_DATABASE_PASSWORD}
    healthcheck:
      test: pg_isready -U postgres -h localhost -d postgres
      interval: 5s
      timeout: 5s
      retries: 10
    restart: always

  redis:
    image: redis
    command: ["--maxmemory-policy", "noeviction"]
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 5s
      retries: 10
    restart: always

volumes:
  db-data:
  server-local-data:
END
}

# crm_write_dotenv FILE: give FILE the two secrets Twenty needs, made here with openssl as
# Twenty's guide says, and never printed. a value already in the file is kept: a new
# ENCRYPTION_KEY would lock Twenty out of what it already encrypted.
crm_write_dotenv() {
  local file="$1" key password
  (
    umask 077
    if [ ! -e "$file" ]; then
      printf '# secrets for Twenty, from sirven add crm. keep this file private and out of any repository.\n' > "$file"
      printf '# losing ENCRYPTION_KEY loses every secret Twenty stored.\n' >> "$file"
    elif [ -s "$file" ] && [ -n "$(tail -c 1 "$file")" ]; then
      printf '\n' >> "$file"
    fi
  ) || return 1
  if ! grep -q '^ENCRYPTION_KEY=.' "$file"; then
    key="$(openssl rand -base64 32)" && [ -n "$key" ] || return 1
    printf 'ENCRYPTION_KEY=%s\n' "$key" >> "$file"
  fi
  if ! grep -q '^PG_DATABASE_PASSWORD=.' "$file"; then
    password="$(openssl rand -hex 32)" && [ -n "$password" ] || return 1
    printf 'PG_DATABASE_PASSWORD=%s\n' "$password" >> "$file"
  fi
  chmod 0600 "$file"
}

# crm_wait_until_up: Twenty migrates its database on first start, which takes minutes.
crm_wait_until_up() {
  local tries=0
  until curl -fsS "$CRM_ADDRESS/healthz" >/dev/null 2>&1; do
    tries=$((tries + 1))
    if [ "$tries" -ge 60 ]; then
      printf 'Twenty did not answer at %s/healthz within 5 minutes. look with: docker compose logs server\n' "$CRM_ADDRESS" >&2
      return 1
    fi
    sleep 5
  done
}

# crm_remove_if_unchanged STAGED FILE: remove FILE only when it is still what add copied.
crm_remove_if_unchanged() {
  [ -e "$2" ] || return 0
  if cmp -s "$1" "$2"; then
    rm -f "$2"
  else
    printf '       kept %s: you changed it, so it is yours\n' "$2"
  fi
}

# crm_compose: the docker compose command line for the owner's copy, with its dotenv.
crm_compose() {
  printf 'docker compose --project-directory %s --env-file %s' "$(rooted "$COMPONENT_DIR")" "$(rooted "$COMPONENT_ENV_FILE")"
}

component_crm_plan_add() {
  local dir compose env staged
  dir="$(rooted "$COMPONENT_DIR")"
  compose="$(rooted "$COMPONENT_DIR/docker-compose.yml")"
  env="$(rooted "$COMPONENT_ENV_FILE")"
  staged="$(crm_compose_file | stage_file crm-docker-compose.yml)"

  plan_section "your copy of the component"
  plan_note "copied for you to own and edit. a file already there is never overwritten."
  plan_step run "create the folder $COMPONENT_DIR" "[ -d $dir ]" "mkdir -p $dir && chmod 0700 $dir"
  plan_step run "copy the Docker Compose file for Twenty $CRM_TWENTY_VERSION" "[ -e $compose ]" \
    "cp $(shell_quote "$staged") $compose && chmod 0644 $compose" \
    "# write $compose (mode 0644): Twenty $CRM_TWENTY_VERSION, its worker, Postgres, and Redis, answering on 127.0.0.1:3000 only"
  plan_step run "put Twenty's two secrets in the dotenv $COMPONENT_ENV_FILE" \
    "grep -q '^ENCRYPTION_KEY=.' $env && grep -q '^PG_DATABASE_PASSWORD=.' $env" \
    "mkdir -p $(rooted "$(dirname "$COMPONENT_ENV_FILE")") && crm_write_dotenv $env" \
    "# write $env (mode 0600): ENCRYPTION_KEY from openssl rand -base64 32, PG_DATABASE_PASSWORD from openssl rand -hex 32.
# made on this machine and never printed. a value already in the file is kept."
  plan_step system "give the folder and the dotenv to the owner, $OWNER" \
    "[ \"\$(ls -ld $dir | awk '{print \$3}')\" = $(shell_quote "$OWNER") ] && [ \"\$(ls -l $env | awk '{print \$3}')\" = $(shell_quote "$OWNER") ]" \
    "chown -R $(shell_quote "$OWNER") $dir && chown $(shell_quote "$OWNER") $env"

  plan_section "run Twenty"
  plan_note "Twenty's guide asks for Docker with Compose 2 or newer and at least 2 gigabytes of memory."
  plan_step system "start Twenty with Docker Compose" \
    "$(crm_compose) ps --status running --quiet server | grep -q ." \
    "$(crm_compose) up -d"
  plan_step system "wait until Twenty answers at $CRM_ADDRESS" \
    "curl -fsS $CRM_ADDRESS/healthz" \
    "crm_wait_until_up" \
    "curl --fail $CRM_ADDRESS/healthz   # every 5 seconds, for up to 5 minutes, while Twenty sets up its database"

  plan_section "make it yours"
  plan_owner "open Twenty and create the first workspace" \
    "open $CRM_ADDRESS in a browser on this machine and sign up, before Twenty is reachable from anywhere else."
  plan_owner "give your agent its own Twenty key, if it should use Twenty" \
    "in Twenty: Settings, APIs and Webhooks, create an API key for your agent.
keep it in a dotenv you control, for example with bb secret, which writes it without the value passing through a transcript.
never put it in a repository."
}

component_crm_plan_remove() {
  local dir compose env staged down="down"
  dir="$(rooted "$COMPONENT_DIR")"
  compose="$(rooted "$COMPONENT_DIR/docker-compose.yml")"
  env="$(rooted "$COMPONENT_ENV_FILE")"
  staged="$(crm_compose_file | stage_file crm-docker-compose.yml)"
  [ "$COMPONENT_REMOVE_DATA" = yes ] && down="down --volumes"

  plan_section "stop Twenty"
  plan_step system "stop Twenty's containers" \
    "! $(crm_compose) ps --all --quiet | grep -q ." \
    "$(crm_compose) $down"
  if [ "$COMPONENT_REMOVE_DATA" = yes ]; then
    plan_note "--remove-data: the Docker volumes with Twenty's database and uploaded files are deleted too."
  else
    plan_note "kept: the Docker volumes with Twenty's database and uploaded files. add --remove-data to delete them."
  fi

  plan_section "your copy of the component"
  plan_step run "remove the Docker Compose file, unless you changed it" "[ ! -e $compose ]" \
    "crm_remove_if_unchanged $(shell_quote "$staged") $compose" \
    "rm -f $compose   # kept if you changed it"
  if [ "$COMPONENT_REMOVE_DATA" != yes ]; then
    plan_note "kept: the dotenv $COMPONENT_ENV_FILE. it holds ENCRYPTION_KEY, and Twenty's data cannot be read without it. add --remove-data to remove it."
  elif [ "$COMPONENT_ENV_FILE" = "$COMPONENT_DIR/.env" ]; then
    plan_step run "remove the dotenv $COMPONENT_ENV_FILE and the secrets in it" "[ ! -e $env ]" "rm -f $env"
  else
    plan_note "kept: the dotenv $COMPONENT_ENV_FILE. you named it with --env-file, so it is not this component's to remove."
  fi
  plan_step run "remove the folder $COMPONENT_DIR if nothing else is inside" "[ ! -d $dir ]" \
    "layout_remove_directory $dir" "rmdir $dir   # kept if anything else is inside"
}
