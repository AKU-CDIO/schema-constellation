/* Author: test */
USE [CDIO_MeditechDB];
GO

SET NOCOUNT ON;

IF OBJECT_ID('dbo.tbl_FCAP1A_Extended_SchemaMetadata', 'U') IS NOT NULL
    DROP TABLE dbo.tbl_FCAP1A_Extended_SchemaMetadata;

CREATE TABLE dbo.tbl_FCAP1A_Extended_SchemaMetadata
(
    SchemaName        SYSNAME        NOT NULL,
    TableName         SYSNAME        NOT NULL,
    ColumnOrder       INT            NOT NULL,
    ColumnName        SYSNAME        NOT NULL,
    DataType          SYSNAME        NOT NULL,
    MaxLength         INT            NULL,
    PrecisionValue    INT            NULL,
    ScaleValue        INT            NULL,
    IsNullable        BIT            NOT NULL,
    IsIdentity        BIT            NOT NULL,
    IsPrimaryKey      BIT            NOT NULL,
    ForeignKeyName    SYSNAME        NULL,
    ReferencedSchema  SYSNAME        NULL,
    ReferencedTable   SYSNAME        NULL,
    ReferencedColumn  SYSNAME        NULL,
    ExtractedOn       DATETIME2(3)   NOT NULL DEFAULT SYSDATETIME()
);

INSERT INTO dbo.tbl_FCAP1A_Extended_SchemaMetadata
(
    SchemaName,
    TableName,
    ColumnOrder,
    ColumnName,
    DataType,
    MaxLength,
    PrecisionValue,
    ScaleValue,
    IsNullable,
    IsIdentity,
    IsPrimaryKey,
    ForeignKeyName,
    ReferencedSchema,
    ReferencedTable,
    ReferencedColumn
)
SELECT
    s.name,
    t.name,
    c.column_id,
    c.name,
    ty.name,
    CASE 
        WHEN ty.name IN ('nvarchar','nchar')
            THEN c.max_length / 2
        ELSE c.max_length
		    END,
    c.precision,
    c.scale,
    c.is_nullable,
    c.is_identity,
    CASE WHEN pk.column_id IS NOT NULL THEN 1 ELSE 0 END,
    fk.name,
    OBJECT_SCHEMA_NAME(fk.referenced_object_id),
    OBJECT_NAME(fk.referenced_object_id),
    rc.name
FROM sys.tables t
INNER JOIN sys.schemas s
    ON t.schema_id = s.schema_id
INNER JOIN sys.columns c
    ON t.object_id = c.object_id
INNER JOIN sys.types ty
    ON c.user_type_id = ty.user_type_id
LEFT JOIN
(
    SELECT ic.object_id, ic.column_id
    FROM sys.indexes i
    INNER JOIN sys.index_columns ic
        ON i.object_id = ic.object_id
       AND i.index_id = ic.index_id
    WHERE i.is_primary_key = 1
) pk
    ON c.object_id = pk.object_id
   AND c.column_id = pk.column_id
LEFT JOIN sys.foreign_key_columns fkc
    ON c.object_id = fkc.parent_object_id
   AND c.column_id = fkc.parent_column_id
LEFT JOIN sys.foreign_keys fk
    ON fkc.constraint_object_id = fk.object_id
LEFT JOIN sys.columns rc
    ON fkc.referenced_object_id = rc.object_id
   AND fkc.referenced_column_id = rc.column_id
WHERE t.name LIKE '%[_]Extended'
ORDER BY
    s.name,
    t.name,
    c.column_id;