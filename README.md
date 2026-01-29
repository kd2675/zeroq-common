# ZeroQ - Space Occupancy & Management Platform

Real-time space occupancy tracking and management platform with microservices architecture.

## 🏗️ Architecture Overview

ZeroQ is built as a **multi-service platform** separating concerns for scalability:

```
┌─────────────────────────────────────────────────────────────┐
│                      Frontend                               │
│  ┌──────────────────┐        ┌──────────────────┐          │
│  │  Admin Portal    │        │  User App        │          │
│  │  (Next.js)       │        │  (Next.js)       │          │
│  └──────────────────┘        └──────────────────┘          │
└──────────────┬──────────────────────────┬───────────────────┘
               │                          │
┌──────────────────────────────────────────────────────────────┐
│                     API Gateway / Load Balancer              │
└──────────────┬──────────────────────────┬───────────────────┘
               │                          │
┌──────────────────────────────────────────────────────────────┐
│                    Microservices Layer                       │
│  ┌─────────────┐  ┌──────────────┐  ┌──────────────┐       │
│  │ API Server  │  │ Sensor       │  │ Analytics    │       │
│  │ (Port 8080) │  │ Server       │  │ Server       │       │
│  │             │  │ (Port 8081)  │  │ (Port 8082)  │       │
│  └─────────────┘  └──────────────┘  └──────────────┘       │
│  ┌─────────────┐                                            │
│  │ Admin       │                                            │
│  │ Server      │                                            │
│  │ (Port 8083) │                                            │
│  └─────────────┘                                            │
└──────────────┬──────────────────────────┬───────────────────┘
               │                          │
┌──────────────────────────────────────────────────────────────┐
│                   Shared Resources                           │
│  ┌──────────────┐        ┌──────────────┐                  │
│  │ MySQL 8      │        │ Common Core  │                  │
│  │ (Database)   │        │ (Shared Lib) │                  │
│  └──────────────┘        └──────────────┘                  │
└──────────────────────────────────────────────────────────────┘
```

## 📦 Service Modules

### 🔵 **zeroq-back-service** - Main API Server
**Port:** `8080`

Core REST API for business logic:
- User management & authentication
- Space management
- Occupancy tracking
- Reviews & ratings
- Favorites management

**Start:** `./gradlew zeroq-back-service:bootRun`

📖 [Detailed Documentation](./zeroq-back-service/README.md)

---

### 🟢 **zeroq-front-admin** - Admin Portal
**Framework:** Next.js 16, React 19, TypeScript

Administrative dashboard for:
- Space management
- Analytics & reports
- User management
- System configuration

**Start:**
```bash
cd zeroq-front-admin
npm install
npm run dev
```

---

### 🟠 **zeroq-front-service** - Customer App
**Framework:** Next.js 16, React 19, TypeScript

Customer-facing application for:
- Browse spaces
- Check occupancy
- Leave reviews
- Manage favorites

**Start:**
```bash
cd zeroq-front-service
npm install
npm run dev
```

---

### 🟣 **web-common-core** - Shared Library
Shared utilities and base classes:
- Common DTOs (ResponseDTO, ResponseDataDTO)
- Utility functions (DateUtils, UuidUtils, HttpUtils)
- Base exception classes
- Common validators

**Usage:** Imported as dependency in all services

---

## 🚀 Quick Start

### Prerequisites
- **Java 21+**
- **Node.js 18+**
- **MySQL 8+**
- **Gradle 9.2.1+**
- **npm** or **yarn**

### Installation

1. **Clone repository**
```bash
cd /Users/harry/project/zeroq/zeroq-common
```

2. **Setup database**
```bash
# Create MySQL database
mysql -u root -p << EOF
CREATE DATABASE zeroq;
CREATE USER 'zeroq'@'localhost' IDENTIFIED BY 'password';
GRANT ALL PRIVILEGES ON zeroq.* TO 'zeroq'@'localhost';
FLUSH PRIVILEGES;
EOF
```

3. **Build all modules**
```bash
./gradlew clean build -x test
```

### Running Services

**All services together:**
```bash
# Terminal 1 - API Server (Port 8080)
./gradlew zeroq-back-service:bootRun

# Terminal 2 - Admin Portal (Port 3000)
cd zeroq-front-admin && npm run dev

# Terminal 3 - Customer App (Port 3001)
cd zeroq-front-service && npm run dev
```

## 📁 Project Structure

```
zeroq-common/
├── zeroq-back-service/           # Main API backend
│   ├── src/main/java/com/zeroq/back/
│   │   ├── security/             # JWT & Authentication
│   │   ├── common/               # Shared infrastructure
│   │   ├── database/pub/         # Data layer (entity/repo/dto)
│   │   └── service/              # Business logic (act/biz/vo)
│   ├── README.md                 # Backend API documentation
│   └── build.gradle
│
├── web-common-core/            # Shared library
│   ├── src/main/java/com/zeroq/core/
│   │   ├── response/             # Common response DTOs
│   │   ├── utils/                # Utility classes
│   │   └── exception/            # Base exceptions
│   └── build.gradle
│
├── zeroq-front-admin/            # Admin portal (Next.js)
│   ├── app/                      # Next.js app router
│   ├── package.json
│   └── README.md
│
├── zeroq-front-service/          # Customer app (Next.js)
│   ├── app/                      # Next.js app router
│   ├── package.json
│   └── README.md
│
├── CLAUDE.md                      # Architecture guidelines
├── settings.gradle               # Gradle multi-module config
└── build.gradle                  # Root Gradle configuration
```

## 📚 Documentation

- **[Backend API Documentation](./zeroq-back-service/README.md)** - REST API endpoints, authentication, configuration
- **[Architecture Guidelines](./CLAUDE.md)** - Code structure patterns, layer responsibilities, design patterns
- **[Backend Service Details](./zeroq-back-service/)** - Detailed implementation documentation

## 🔐 Security

- **JWT Authentication** - Stateless token-based authentication
- **Role-Based Access Control** - USER, OWNER, ADMIN roles
- **CORS** - Cross-origin request handling configured
- **Input Validation** - Jakarta Bean Validation throughout

**Note:** Review CORS configuration in production (currently allows all origins)

## 🛠️ Build & Deployment

### Development
```bash
./gradlew build -x test
./gradlew zeroq-back-service:bootRun
```

### Production Build
```bash
./gradlew clean build
java -jar zeroq-back-service/build/libs/zeroq-back-service-0.0.1-SNAPSHOT.jar
```

### Environment Profiles
```bash
# Local (default)
./gradlew bootRun --args='--spring.profiles.active=local'

# Development
./gradlew bootRun --args='--spring.profiles.active=dev'

# Production
./gradlew bootRun --args='--spring.profiles.active=prod'
```

## 📊 API Overview

**Base URL:** `http://localhost:8080/api/v1`

### Main Endpoints
- `POST /auth/signup` - User registration
- `POST /auth/login` - User login
- `GET /spaces` - List all spaces
- `GET /occupancy/spaces/{id}` - Current occupancy
- `GET /reviews/spaces/{id}` - Space reviews
- `POST /favorites/{spaceId}` - Add to favorites

📖 Full API documentation: [Backend README](./zeroq-back-service/README.md#api-endpoints)

## 🧪 Testing

```bash
# Run all tests
./gradlew test

# Run specific module tests
./gradlew zeroq-back-service:test

# Run single test
./gradlew zeroq-back-service:test --tests com.zeroq.back.SomeTest
```

## 📝 Database

- **Type:** MySQL 8
- **DDL Management:** Manual (Hibernate ddl-auto: validate)
- **ORM:** Spring Data JPA with Hibernate
- **Connection:** Master-Slave architecture support
- **Entities:** 25 core entities with relationships

## 🤝 Contributing

### Adding New Features

1. Follow [Architecture Guidelines](./CLAUDE.md)
2. Organize by domain: `service/{domain}/(act|biz|vo)`
3. Create Entity → Repository → DTO → Service → Controller
4. Add unit tests in `src/test/java`
5. Update documentation

### Code Standards
- **Java Version:** 21
- **Code Style:** Google Java Style Guide
- **Lombok Usage:** Reduce boilerplate with @Getter, @Setter, @Builder, @Slf4j
- **Validation:** Use Jakarta Bean Validation annotations

## 🚨 Troubleshooting

### Port Already in Use
```bash
# Change port in application.yml
server:
  port: 8081
```

### Database Connection Failed
- Verify MySQL is running
- Check credentials in `application-{profile}.yml`
- Ensure database exists

### JWT Token Errors
- Verify JWT secret is configured
- Check token expiration times
- Ensure Authorization header format: `Bearer {token}`

## 📞 Support

For issues, questions, or feature requests, contact the development team.

---

## 📈 Roadmap

- [ ] Microservice separation (Sensor, Analytics servers)
- [ ] Real-time WebSocket updates
- [ ] Advanced analytics & reporting
- [ ] Mobile native apps
- [ ] Sensor integration with IoT platform
- [ ] Cache layer optimization (Redis)

## 📅 Version

**Current Version:** 0.0.1-SNAPSHOT

**Last Updated:** January 2024

---

## 📄 License

Proprietary - All rights reserved

