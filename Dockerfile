FROM golang:alpine AS hugo-build
MAINTAINER Kellen Frodelius-Fujimoto <kellen@kellenfujimoto.com>

RUN apk add --no-cache gcc g++ make ca-certificates git

# install hugo
RUN git clone --single-branch --branch stable https://github.com/gohugoio/hugo.git /tmp/hugo

WORKDIR /tmp/hugo

RUN go install --tags extended

RUN echo `which hugo`

FROM alpine
MAINTAINER Kellen Frodelius-Fujimoto <kellen@kellenfujimoto.com>

WORKDIR /usr/bin
COPY --from=hugo-build /go/bin/hugo .

COPY . /site

WORKDIR /site

CMD hugo -d /var/www/kellenfujimoto.com
