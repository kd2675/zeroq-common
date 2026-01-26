# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ZeroQ is a full-stack application with a multi-module architecture:
- **zeroq-common-core**: Shared Java library with common utilities, response/error handling, and base infrastructure (Spring Boot 4.0.1, Java 21)
- **zeroq-back-service**: Spring Boot REST API backend that depends on zeroq-common-core
- **zeroq-front-admin**: Next.js admin interface (React 19, TypeScript, Tailwind CSS)
- **zeroq-front-service**: Next.js customer-facing service (React 19, TypeScript, Tailwind CSS)

The project uses a Gradle multi-module build system (root: `zeroq-common`).

## Backend Architecture

### Layered Architecture Pattern: act/biz/vo

The backend uses a **3-tier layered architecture** where each service domain is organized into:
- **act** (Action/Controller): HTTP request/response handling
- **biz** (Business): Core business logic
- **vo** (Value Object): Domain-specific objects (optional)

**Package Structure:**
```
src/main/java/com/zeroq/back/
├── security/                    # JWT & Authentication layer
├── common/                      # Shared Infrastructure
│   ├── config/                  # Spring configurations (JPA, MVC, Security, etc.)
│   ├── exception/               # Exception handling and mapping
│   ├── datasource/              # Database connection/routing
│   ├── jpa/                     # Base entity and DTO classes
│   └── logback/                 # Logging configuration
├── database/pub/                # Data Access Layer
│   ├── entity/                  # JPA Entity classes
│   ├── repository/              # Spring Data JPA Repository interfaces
│   └── dto/                     # DTOs & Request/Response objects
└── service/                     # Business Logic Layer
    └── {domain}/                # Each domain organized by act/biz/vo
        ├── act/                 # Controllers (HTTP endpoints)
        ├── biz/                 # Services (business logic)
        └── vo/                  # Value Objects (domain logic, optional)
```

### Directory Organization for New Domains

For each new **domain** (e.g., user, order, product, payment):

```
service/{domain}/
├── act/
│   ├── {Domain}Controller.java              # Main HTTP endpoints
│   └── {DomainDetail}Controller.java         # (optional) Sub-resource controller
├── biz/
│   ├── {Domain}Service.java                 # Main business logic
│   └── {DomainDetail}Service.java           # (optional) Complex operations
└── vo/
    ├── {Domain}VO.java                      # (optional) Complex domain object
    └── {Domain}AggregateVO.java             # (optional) Aggregate patterns
```

### Layer Responsibilities & File Organization

| Layer | Location | File Pattern | Responsibility |
|-------|----------|--------------|-----------------|
| **Entity** | `database/pub/entity/` | `{Entity}.java` | DB mapping, relationships, `@Id`, `@Column`, `@ManyToOne`, `@OneToMany` |
| **Repository** | `database/pub/repository/` | `{Entity}Repository.java` | Data queries, extends `JpaRepository<Entity, Long>`, no business logic |
| **DTO** | `database/pub/dto/` | `{Entity}DTO.java`, `Create/Update{Entity}Request.java` | API data transfer, `@Valid` validation, static `from()` conversion method |
| **VO** | `service/{domain}/vo/` | `{Domain}VO.java` | Complex domain logic, immutable with `@Value`, encapsulation |
| **Service** | `service/{domain}/biz/` | `{Domain}Service.java` | Business logic, transactions, coordination, validation |
| **Controller** | `service/{domain}/act/` | `{Domain}Controller.java` | HTTP routing, `@RequestMapping`, input validation, response wrapping |

### Data Flow Pattern

```
HTTP Request (JSON body)
    ↓
@RestController (act/)
├─ Extract: @PathVariable, @RequestParam, @RequestBody
├─ Validate: @Valid annotation
└─ Call: Service method
    ↓
@Service (biz/)
├─ Business validation
├─ Query Repository
├─ Process VO (if complex logic)
├─ Entity → DTO conversion
└─ Return DTO
    ↓
@Repository
├─ JPA query/persist via Spring Data
└─ Return Entity
    ↓
@RestController
├─ Wrap DTO in ResponseDataDTO
└─ Return: ResponseEntity<ResponseDataDTO<DTO>>
    ↓
HTTP Response (200 OK with JSON)
```

### API Endpoint Pattern

All endpoints follow: `/api/v1/{domain}/{resource}`

**Standard REST Operations:**
```
POST   /api/v1/{domain}              Create new {domain}
GET    /api/v1/{domain}/{id}         Get single {domain}
GET    /api/v1/{domain}              List {domain} (with Pageable)
PUT    /api/v1/{domain}/{id}         Update {domain}
DELETE /api/v1/{domain}/{id}         Delete {domain}
GET    /api/v1/{domain}/search       Search/filter {domain}
GET    /api/v1/{domain}/page         Get paginated list
```

### Common Infrastructure Modules

**security/** - JWT & Authentication
- `JwtTokenProvider` - Token generation/validation
- `JwtAuthenticationFilter` - JWT filter
- `CustomUserDetailsService` - User details service

**common/config/** - Spring Configurations
- `JpaConfig.java` - JPA and entity manager setup
- `MvcConfig.java` - MVC and component scan
- `SecurityConfig.java` - Spring Security configuration

**common/exception/** - Centralized Error Handling
- `GlobalExceptionHandler` - `@ExceptionHandler` methods
- Custom exception classes (ResourceNotFoundException, ConflictException, etc.)
- Returns: `ResponseErrorDTO` via `GlobalExceptionHandler`

**common/jpa/** - Base Classes for All Entities
- `CommonDateEntity` - Base entity with auto-audited `createDate`, `updateDate`
- `CommonUserEntity` - Extends CommonDateEntity, adds `createUser`, `updateUser`
- `CommonDateDTO` - Base DTO with `createDate`, `updateDate`

**database/pub/PubDataConfig** - Database Configuration
- Entity/Repository scan paths
- Master-Slave routing configuration

**zeroq-common-core** (Dependency) - Shared Utilities
- `ResponseDTO`, `ResponseDataDTO`, `ResponseErrorDTO`
- Utility classes (DateUtils, UuidUtils, HttpUtils, etc.)
- `GeneralException` base class

## Build and Development

### Common Gradle Tasks
```bash
# Build the entire project (runs tests)
./gradlew build

# Build without tests
./gradlew build -x test

# Run backend service
./gradlew zeroq-back-service:bootRun

# Run different server modules
./gradlew :livespace-server-api:bootRun              # API 서버
./gradlew :livespace-server-sensor:bootRun           # 센서 서버 (데이터 수집 부하 증가 시)
./gradlew :livespace-server-analytics:bootRun        # 분석 서버 (배치 작업 분리)
./gradlew :livespace-server-admin:bootRun            # 관리자 서버

# Run tests for a specific module
./gradlew zeroq-back-service:test
./gradlew zeroq-common-core:test

# Run a single test
./gradlew zeroq-back-service:test --tests com.zeroq.back.SomeTest

# Clean build artifacts
./gradlew clean

# Assemble JAR files (without running tests)
./gradlew assemble
```

### Frontend Development
```bash
# Navigate to frontend directory
cd zeroq-front-admin  # or zeroq-front-service

# Install dependencies
npm install

# Development server
npm run dev

# Build for production
npm run build

# Start production server
npm start

# Run linting
npm run lint
```

## Running Tests

### Backend Tests
- Both modules use JUnit 5 with `useJUnitPlatform()`
- Test configuration uses `application-test.yml` profile
- Run all tests: `./gradlew test`
- Run single test: `./gradlew test --tests ClassName`

### Frontend Tests
- Configure via test script in `package.json` (currently linting is primary check)

## Application Configuration

### Backend Properties
Key properties in `application.yml` and environment-specific overrides:
- **JWT**: Secret key and expiration times (24 hours for access, 7 days for refresh)
- **Database**: Hibernate `ddl-auto` set to validate (manual schema management required)
- **Jackson**: Date format is `yyyy-MM-dd HH:mm:ss`
- **File Upload**: Max file size 100MB, max request size 100MB
- **Actuator**: Health, metrics, and info endpoints enabled at `/actuator`
- **JPA**: Open-in-view disabled, batch operations configured

### Profiles
- **local**: Development profile (default in `application.yml`)
- **dev**: Development environment
- **test**: Test environment
- **prod**: Production environment

## Architecture Pattern: Creating a New Feature

When adding a new feature/domain to zeroq-back-service, follow this abstract architecture pattern:

### 1. Entity Layer (database/pub/entity/)

**What**: JPA-annotated class representing database table
**Extends**: `CommonDateEntity` (provides auto-audited `createDate`, `updateDate`)
**Annotations**: `@Entity`, `@Table`, `@Getter`, `@Setter`, `@NoArgsConstructor`, `@AllArgsConstructor`, `@Builder`

```java
@Entity
@Table(name = "table_name")
@Getter
@Setter
@NoArgsConstructor
@AllArgsConstructor
@Builder
public class MyEntity extends CommonDateEntity {
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(nullable = false)
    private String name;

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "related_id")
    private RelatedEntity relatedEntity;

    @Index(name = "idx_name")
    // Indexes for commonly queried fields
}
```

**Key Points**:
- Always use `CommonDateEntity` as parent (provides audit fields)
- Use `@ManyToOne` with `FetchType.LAZY` for relationships
- Add `@Index` on frequently queried fields
- Use `@Builder` for entity construction
- Keep entities lean (no business logic)

---

### 2. Repository Layer (database/pub/repository/)

**What**: Spring Data JPA interface for data access
**Extends**: `JpaRepository<Entity, Long>`
**Location**: `src/main/java/com/zeroq/back/database/pub/repository/`

```java
@Repository
public interface MyEntityRepository extends JpaRepository<MyEntity, Long> {
    // Derived query methods (auto-implemented by Spring Data)
    Page<MyEntity> findByNameOrderByCreateDateDesc(String name, Pageable pageable);

    long countByNameAndActive(String name, boolean active);

    List<MyEntity> findByRelatedEntityIdAndDeletedFalse(Long relatedId);

    // Custom queries
    @Query("SELECT m FROM MyEntity m WHERE m.name = :name AND m.active = true")
    Optional<MyEntity> findActiveByName(@Param("name") String name);

    @Query("SELECT COUNT(m) FROM MyEntity m WHERE m.relatedEntity.id = :relatedId")
    long countByRelatedEntity(@Param("relatedId") Long relatedId);
}
```

**Key Points**:
- Extend `JpaRepository<Entity, Long>`
- Use Spring Data derived query methods for simple queries
- Use `@Query` for complex queries with JPQL
- Use property names from Entity (not column names)
- Always use `Pageable` for list endpoints
- Use `Optional<>` for single result queries

---

### 3. DTO Layer (database/pub/dto/)

**What**: Data Transfer Object for API request/response
**Never**: Don't put business logic; only data
**Extends**: Optionally `CommonDateDTO` for response DTOs

```java
// Response DTO (extends CommonDateDTO)
@Getter
@Setter
@NoArgsConstructor
@AllArgsConstructor
@Builder
public class MyEntityDTO extends CommonDateDTO {
    private Long id;
    private String name;
    private String description;
    private Long relatedEntityId;
    private String relatedEntityName;

    // Conversion from Entity
    public static MyEntityDTO from(MyEntity entity) {
        return MyEntityDTO.builder()
            .id(entity.getId())
            .name(entity.getName())
            .description(entity.getDescription())
            .relatedEntityId(entity.getRelatedEntity().getId())
            .relatedEntityName(entity.getRelatedEntity().getName())
            .createDate(entity.getCreateDate())
            .updateDate(entity.getUpdateDate())
            .build();
    }
}

// Request DTO (for POST/PUT)
@Getter
@Setter
@NoArgsConstructor
@AllArgsConstructor
public class CreateMyEntityRequest {
    @NotBlank(message = "Name is required")
    private String name;

    private String description;

    @NotNull(message = "Related entity ID is required")
    private Long relatedEntityId;
}
```

**Key Points**:
- Response DTO extends `CommonDateDTO` (includes audit fields)
- Request DTO is separate (no audit fields)
- Include `from(Entity)` static method for Entity→DTO conversion
- Use `@NotNull`, `@NotBlank` for validation
- Never include sensitive fields (passwords, tokens)
- Keep DTOs simple; no nested complex objects

---

### 4. Service Layer (service/{domain}/biz/)

**What**: Business logic implementation
**Annotations**: `@Service`, `@RequiredArgsConstructor`, `@Transactional`
**Naming**: `{Entity}Service.java`

```java
@Slf4j
@Service
@RequiredArgsConstructor
@Transactional(readOnly = true)
public class MyEntityService {

    private final MyEntityRepository myEntityRepository;
    private final RelatedEntityRepository relatedEntityRepository;

    // READ operation (readOnly = true by default)
    public Page<MyEntityDTO> getAll(Pageable pageable) {
        return myEntityRepository.findAll(pageable)
            .map(MyEntityDTO::from);
    }

    public MyEntityDTO getById(Long id) {
        return myEntityRepository.findById(id)
            .map(MyEntityDTO::from)
            .orElseThrow(() -> new LiveSpaceException.ResourceNotFoundException(
                "MyEntity", "id", id));
    }

    // CREATE operation (requires @Transactional, no readOnly)
    @Transactional
    public MyEntityDTO create(CreateMyEntityRequest request) {
        // 1. Validate related entity exists
        RelatedEntity relatedEntity = relatedEntityRepository.findById(request.getRelatedEntityId())
            .orElseThrow(() -> new LiveSpaceException.ResourceNotFoundException(
                "RelatedEntity", "id", request.getRelatedEntityId()));

        // 2. Check for duplicates if needed
        if (myEntityRepository.findByName(request.getName()).isPresent()) {
            throw new LiveSpaceException.ConflictException("Name already exists");
        }

        // 3. Create entity
        MyEntity entity = MyEntity.builder()
            .name(request.getName())
            .description(request.getDescription())
            .relatedEntity(relatedEntity)
            .build();

        // 4. Save and return DTO
        return MyEntityDTO.from(myEntityRepository.save(entity));
    }

    // UPDATE operation
    @Transactional
    public MyEntityDTO update(Long id, CreateMyEntityRequest request) {
        MyEntity entity = myEntityRepository.findById(id)
            .orElseThrow(() -> new LiveSpaceException.ResourceNotFoundException(
                "MyEntity", "id", id));

        entity.setName(request.getName());
        entity.setDescription(request.getDescription());

        return MyEntityDTO.from(myEntityRepository.save(entity));
    }

    // DELETE operation
    @Transactional
    public void delete(Long id) {
        if (!myEntityRepository.existsById(id)) {
            throw new LiveSpaceException.ResourceNotFoundException(
                "MyEntity", "id", id);
        }
        myEntityRepository.deleteById(id);
    }
}
```

**Key Points**:
- Inject repositories via constructor (`@RequiredArgsConstructor`)
- Use `@Transactional(readOnly = true)` at class level (default for GET)
- Override with `@Transactional` (no readOnly) for CREATE/UPDATE/DELETE
- Always validate related entities exist before using them
- Throw `LiveSpaceException` subclasses for error handling
- Use repository methods for queries
- Keep business logic separate from HTTP concerns
- Log important operations using `@Slf4j`

---

### 5. VO Layer (service/{domain}/vo/)

**What**: Domain Value Objects (optional, use when needed)
**When to use**: Complex domain logic, immutable objects, multiple related values

```java
// Value Object for complex logic
@Value  // Lombok: immutable with getters
@Builder
public class OccupancyVO {
    private Integer currentOccupancy;
    private Integer maxCapacity;
    private Double percentage;
    private CrowdLevel level;

    // Domain logic encapsulated in VO
    public static OccupancyVO from(OccupancyData data) {
        int currentOccupancy = data.getCurrentOccupancy();
        int maxCapacity = data.getMaxCapacity();
        double percentage = (double) currentOccupancy / maxCapacity * 100;
        CrowdLevel level = CrowdLevel.fromOccupancyPercentage(percentage);

        return OccupancyVO.builder()
            .currentOccupancy(currentOccupancy)
            .maxCapacity(maxCapacity)
            .percentage(percentage)
            .level(level)
            .build();
    }

    // Domain methods
    public boolean isFull() {
        return level == CrowdLevel.FULL;
    }

    public boolean isEmpty() {
        return level == CrowdLevel.EMPTY;
    }
}
```

**Key Points**:
- Use `@Value` from Lombok for immutability
- Encapsulate domain logic
- Use in Service and Controller
- Optional: only use for complex domain models

---

### 6. Controller Layer (service/{domain}/act/)

**What**: HTTP request/response handling
**Annotations**: `@RestController`, `@RequestMapping`, `@RequiredArgsConstructor`
**Naming**: `{Entity}Controller.java`

```java
@Slf4j
@RestController
@RequestMapping("/api/v1/my-entities")
@RequiredArgsConstructor
public class MyEntityController {

    private final MyEntityService myEntityService;

    // GET list with pagination
    @GetMapping
    public ResponseEntity<ResponseDataDTO<Page<MyEntityDTO>>> getAll(
            @PageableDefault(size = 20, sort = "createDate", direction = Sort.Direction.DESC)
            Pageable pageable) {
        Page<MyEntityDTO> data = myEntityService.getAll(pageable);
        return ResponseEntity.ok(ResponseDataDTO.of(data, "Success"));
    }

    // GET single item
    @GetMapping("/{id}")
    public ResponseEntity<ResponseDataDTO<MyEntityDTO>> getById(@PathVariable Long id) {
        MyEntityDTO data = myEntityService.getById(id);
        return ResponseEntity.ok(ResponseDataDTO.of(data, "Success"));
    }

    // POST create
    @PostMapping
    public ResponseEntity<ResponseDataDTO<MyEntityDTO>> create(
            @Valid @RequestBody CreateMyEntityRequest request) {
        MyEntityDTO data = myEntityService.create(request);
        return ResponseEntity.status(HttpStatus.CREATED)
            .body(ResponseDataDTO.of(data, "Created successfully"));
    }

    // PUT update
    @PutMapping("/{id}")
    public ResponseEntity<ResponseDataDTO<MyEntityDTO>> update(
            @PathVariable Long id,
            @Valid @RequestBody CreateMyEntityRequest request) {
        MyEntityDTO data = myEntityService.update(id, request);
        return ResponseEntity.ok(ResponseDataDTO.of(data, "Updated successfully"));
    }

    // DELETE
    @DeleteMapping("/{id}")
    public ResponseEntity<ResponseDataDTO<Void>> delete(@PathVariable Long id) {
        myEntityService.delete(id);
        return ResponseEntity.status(HttpStatus.NO_CONTENT).build();
    }
}
```

**Key Points**:
- Inject only Service (never Repository directly)
- Use `@PathVariable` for URL parameters
- Use `@RequestBody` with `@Valid` for request validation
- Return `ResponseDataDTO` for success
- `GlobalExceptionHandler` catches exceptions and returns `ResponseErrorDTO`
- Use appropriate HTTP status codes
- Use `@PageableDefault` for pagination
- Never expose Entity directly; always use DTO

---

### 7. Data Flow Diagram

```
HTTP Request (JSON)
    ↓
Controller (act/)
    ├─ Extract @PathVariable, @RequestBody
    ├─ Validate with @Valid
    └─ Call Service
    ↓
Service (biz/)
    ├─ Business logic validation
    ├─ Call Repository for DB operations
    ├─ VO processing (if complex)
    └─ DTO conversion
    ↓
Repository
    ├─ Query/Persist Entity
    └─ Return Entity
    ↓
Service
    └─ Entity → DTO conversion
    ↓
Controller
    └─ DTO → ResponseDataDTO wrapper
    ↓
HTTP Response (JSON)
```

---

### 8. Exception Handling Pattern

```java
// In Service:
@Transactional
public MyEntityDTO update(Long id, CreateMyEntityRequest request) {
    MyEntity entity = myEntityRepository.findById(id)
        .orElseThrow(() -> new LiveSpaceException.ResourceNotFoundException(
            "MyEntity", "id", id));  // ← Throw here

    // ... update logic

    return MyEntityDTO.from(myEntityRepository.save(entity));
}

// Global handler catches and converts to ErrorResponse:
@ExceptionHandler(LiveSpaceException.ResourceNotFoundException.class)
public ResponseEntity<ResponseErrorDTO> handleResourceNotFound(
        LiveSpaceException.ResourceNotFoundException ex) {
    // Automatically converted to HTTP 404 with ErrorResponse JSON
}
```

**Exception Hierarchy**:
- `LiveSpaceException` (base)
  - `ResourceNotFoundException` → HTTP 404
  - `ConflictException` → HTTP 409
  - `UnauthorizedException` → HTTP 401

---

### 9. Summary: Layer Responsibilities

| Layer | Responsibility | Example |
|-------|-----------------|---------|
| **Entity** | Database representation | `User`, `Space` |
| **Repository** | Data access | `findByNameOrderByCreateDateDesc()` |
| **DTO** | API data transfer | `UserDTO`, `CreateUserRequest` |
| **VO** | Domain logic (optional) | `OccupancyVO` (calculation) |
| **Service** | Business logic | Validation, coordination, calculations |
| **Controller** | HTTP handling | Route, validate input, format response |

### 10. Creating a New Feature: Step-by-Step

1. **Create Entity** → `database/pub/entity/NewEntity.java`
2. **Create Repository** → `database/pub/repository/NewEntityRepository.java`
3. **Create DTOs** → `database/pub/dto/NewEntityDTO.java`, `CreateNewEntityRequest.java`
4. **Create Service** → `service/newdomain/biz/NewEntityService.java`
5. **Create VO (optional)** → `service/newdomain/vo/NewEntityVO.java`
6. **Create Controller** → `service/newdomain/act/NewEntityController.java`
7. **Register in Config** → Update `PubDataConfig.java` if needed

## Key Implementation Notes

1. **Error Handling**: Use `LiveSpaceException` subclasses from common/exception/
2. **Response Format**: All API responses use `ResponseDataDTO` for success, `ResponseErrorDTO` for errors
3. **Database**: Schema changes require manual management (ddl-auto: validate). No automatic migrations.
4. **Frontend**: Both Next.js apps use modern React patterns with TypeScript and Tailwind CSS
5. **JPA Repositories**: Auto-configuration is disabled; repositories must be explicitly managed
6. **Transactions**: Services use `@Transactional(readOnly = true)` by default, override for writes

## Environment and Dependencies

- **Java Version**: 21 (specified in toolchain)
- **Spring Boot**: 4.0.1
- **Spring Dependency Management**: 1.1.7
- **Key Backend Libraries**:
  - Spring Data JPA
  - Spring Security
  - Spring Data Redis (with Lettuce)
  - JWT (JJWT 0.12.3)
  - MySQL Connector (8.3.0)
  - Lombok (annotation processor)
- **Frontend**: Next.js 16.x, React 19, TypeScript, Tailwind CSS with PostCSS 4