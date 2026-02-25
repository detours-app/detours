import Foundation
import SQLite3

struct ICloudSharedRootRecord: Sendable {
    let relativePath: String
    let creatorID: Int
    let isDirectory: Bool
}

enum ICloudSharedRootsDatabase {
    static func loadSharedRootRecords() -> [ICloudSharedRootRecord] {
        let databaseURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CloudDocs/session/db/client.db")
            .standardizedFileURL
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return []
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db else {
            if let db {
                sqlite3_close(db)
            }
            return []
        }
        defer {
            sqlite3_close(db)
        }

        let sql = """
        WITH roots AS (
            SELECT rowid, item_id, item_parent_id, item_filename, item_creator, item_sharing_options, item_type
            FROM client_items
            WHERE item_user_visible = 1
              AND (item_sharing_options & 4) != 0
        ),
        rec(rowid, item_id, item_parent_id, path, depth, item_creator, item_type) AS (
            SELECT rowid, item_id, item_parent_id, item_filename, 0, item_creator, item_type
            FROM roots
            UNION ALL
            SELECT
                rec.rowid,
                parent.item_id,
                parent.item_parent_id,
                parent.item_filename || '/' || rec.path,
                rec.depth + 1,
                rec.item_creator,
                rec.item_type
            FROM client_items AS parent
            JOIN rec ON rec.item_parent_id = parent.item_id
            WHERE rec.item_parent_id != X'0101000000'
              AND rec.depth < 64
        ),
        max_depth AS (
            SELECT rowid, MAX(depth) AS depth
            FROM rec
            GROUP BY rowid
        )
        SELECT rec.path, rec.item_creator, rec.item_type
        FROM rec
        JOIN max_depth ON max_depth.rowid = rec.rowid AND max_depth.depth = rec.depth
        ORDER BY rec.path;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            if let statement {
                sqlite3_finalize(statement)
            }
            return []
        }
        defer {
            sqlite3_finalize(statement)
        }

        var records: [ICloudSharedRootRecord] = []
        var seenPaths: Set<String> = []

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let pathCString = sqlite3_column_text(statement, 0) else { continue }
            let relativePath = String(cString: pathCString)
            let creatorID = Int(sqlite3_column_int(statement, 1))
            let itemType = Int(sqlite3_column_int(statement, 2))
            let normalizedPath = relativePath.precomposedStringWithCanonicalMapping

            guard seenPaths.insert(normalizedPath).inserted else { continue }
            records.append(
                ICloudSharedRootRecord(
                    relativePath: relativePath,
                    creatorID: creatorID,
                    isDirectory: itemType == 0
                )
            )
        }

        return records
    }
}
