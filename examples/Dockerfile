FROM ruby:3.0.2-alpine

RUN apk add --update \
  libxml2-dev \
  build-base \
  linux-headers \
  git \
  postgresql-dev \
  nodejs \
  npm \
  tzdata

RUN mkdir /app
WORKDIR /app

COPY Gemfile Gemfile.lock package.json yarn.lock /app/
RUN gem install bundler
RUN bundle install -j12
RUN npm install -g yarn
RUN yarn

COPY . /app
RUN bundle exec rake assets:precompile

# Start the main process.
CMD ["bin/rails", "server"]
