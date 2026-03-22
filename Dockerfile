# syntax=docker/dockerfile:1

# ---- Builder stage ----
FROM ruby:3.2.2-slim AS builder

RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
      build-essential \
      libpq-dev \
      git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY Gemfile Gemfile.lock ./
RUN bundle install --jobs 4 --retry 3

# ---- Final stage ----
FROM ruby:3.2.2-slim

RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
      libpq5 \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --system rails && useradd --system --gid rails --home /app rails

WORKDIR /app

COPY --from=builder /usr/local/bundle /usr/local/bundle
COPY --chown=rails:rails . .

USER rails

ENV RAILS_ENV=development \
    RAILS_LOG_TO_STDOUT=true

EXPOSE 3000

CMD ["bin/rails", "server", "-b", "0.0.0.0"]
