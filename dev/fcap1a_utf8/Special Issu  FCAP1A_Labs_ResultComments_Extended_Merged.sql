/* Author: test */
USE [CDIO_MeditechDB];
GO

IF OBJECT_ID('dbo.tbl_FCAP1A_Labs_ResultComments_Extended_Merged','U') IS NOT NULL
    DROP TABLE dbo.tbl_FCAP1A_Labs_ResultComments_Extended_Merged;
GO

CREATE TABLE dbo.tbl_FCAP1A_Labs_ResultComments_Extended_Merged
(
    MergedCommentRowID INT IDENTITY(1,1) PRIMARY KEY,

    PatientID          NVARCHAR(255) NOT NULL,
    VisitID            NVARCHAR(255) NULL,
    SpecimenID         NVARCHAR(255) NOT NULL,
    TestID             NVARCHAR(255) NOT NULL,
    SourceID           VARCHAR(3)    NOT NULL,

    FullResultComment  NVARCHAR(MAX) NULL,

    FirstRowUpdateDateTime DATETIME NULL,
    LastRowUpdateDateTime  DATETIME NULL,
    LineCount              INT NOT NULL,

    ExtractedOn        DATETIME NOT NULL DEFAULT GETDATE()
);
GO


INSERT INTO dbo.tbl_FCAP1A_Labs_ResultComments_Extended_Merged
(
    PatientID,
    VisitID,
    SpecimenID,
    TestID,
    SourceID,
    FullResultComment,
    FirstRowUpdateDateTime,
    LastRowUpdateDateTime,
    LineCount
)
SELECT
    PatientID,
    VisitID,
    SpecimenID,
    TestID,
    SourceID,

    STRING_AGG(
        CAST(TextLine AS NVARCHAR(MAX)),
        CHAR(13) + CHAR(10)
    ) WITHIN GROUP (ORDER BY TextSeqID),

    MIN(RowUpdateDateTime),
    MAX(RowUpdateDateTime),
    COUNT(*)   -- now true logical line count

FROM
(
    -- collapse duplicates at the TextSeqID level
    SELECT
        PatientID,
        VisitID,
        SpecimenID,
        TestID,
        SourceID,
        TextSeqID,
        MAX(TextLine) AS TextLine,
        MAX(RowUpdateDateTime) AS RowUpdateDateTime
    FROM dbo.tbl_FCAP1A_Labs_ResultComments_Extended
    GROUP BY
        PatientID,
        VisitID,
        SpecimenID,
        TestID,
        SourceID,
        TextSeqID
) d
GROUP BY
    PatientID,
    VisitID,
    SpecimenID,
    TestID,
    SourceID;
GO