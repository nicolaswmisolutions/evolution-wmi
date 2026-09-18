# O manager é um submódulo (evolution-manager-v2) e precisa ser compilado aqui.
# Antes, a imagem copiava o manager/dist commitado, então qualquer mudança de
# UI só chegava em /manager se alguém lembrasse de commitar o bundle — e
# ninguém lembrava. Exige `git submodule update --init --recursive` no clone.
FROM node:22-alpine AS manager-build

WORKDIR /usr/src/manager

COPY ./evolution-manager-v2/package*.json ./
RUN npm ci --ignore-scripts

COPY ./evolution-manager-v2/src ./src
COPY ./evolution-manager-v2/public ./public
COPY ./evolution-manager-v2/index.html ./evolution-manager-v2/components.json ./evolution-manager-v2/vite.config.ts ./
COPY ./evolution-manager-v2/tsconfig.json ./evolution-manager-v2/tsconfig.app.json ./evolution-manager-v2/tsconfig.node.json ./

# Sem modo demo: esta imagem serve o manager junto da API real.
ENV VITE_DEMO_MODE=false
RUN npm run build

FROM node:24-alpine AS builder

RUN apk update && \
    apk add --no-cache git ffmpeg wget curl bash openssl

LABEL version="2.3.1" description="Api to control whatsapp features through http requests." 
LABEL maintainer="Davidson Gomes" git="https://github.com/DavidsonGomes"
LABEL contact="contato@evolution-api.com"

WORKDIR /evolution

COPY ./package*.json ./
COPY ./tsconfig.json ./
COPY ./tsup.config.ts ./

RUN npm ci --silent

COPY ./src ./src
COPY ./public ./public
COPY ./prisma ./prisma
COPY --from=manager-build /usr/src/manager/dist ./manager/dist
COPY ./.env.example ./.env
COPY ./runWithProvider.js ./

COPY ./Docker ./Docker

RUN chmod +x ./Docker/scripts/* && dos2unix ./Docker/scripts/*

RUN ./Docker/scripts/generate_database.sh

RUN npm run build

FROM node:24-alpine AS final

RUN apk update && \
    apk add tzdata ffmpeg bash openssl

ENV TZ=America/Sao_Paulo
ENV DOCKER_ENV=true

WORKDIR /evolution

COPY --from=builder /evolution/package.json ./package.json
COPY --from=builder /evolution/package-lock.json ./package-lock.json

COPY --from=builder /evolution/node_modules ./node_modules
COPY --from=builder /evolution/dist ./dist
COPY --from=builder /evolution/prisma ./prisma
COPY --from=builder /evolution/manager ./manager
COPY --from=builder /evolution/public ./public
COPY --from=builder /evolution/.env ./.env
COPY --from=builder /evolution/Docker ./Docker
COPY --from=builder /evolution/runWithProvider.js ./runWithProvider.js
COPY --from=builder /evolution/tsup.config.ts ./tsup.config.ts

ENV DOCKER_ENV=true

EXPOSE 8080

ENTRYPOINT ["/bin/bash", "-c", ". ./Docker/scripts/deploy_database.sh && npm run start:prod" ]
