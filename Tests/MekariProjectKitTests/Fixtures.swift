import Foundation

/// BE response bodies in the exact shape the BE sends (SPEC §5, §12), including nulls and both
/// timestamp forms.
enum Fixtures {
  static let alice = ##"{"id":"u-alice","name":"Alice Johnson","email":"alice@example.com","avatarColor":"#e8384f"}"##
  static let bob = ##"{"id":"u-bob","name":"Bob Smith","email":"bob@example.com","avatarColor":"#20aaea"}"##

  static let workspace = ##"""
  {"id":"ws-1","name":"Mekari","isOrganization":true,"domain":"example.com","color":"#4186e0","myRole":"MEMBER",
   "memberCount":3,"createdAt":"2026-10-18T09:00:00.000Z"}
  """##

  static let me = ##"""
  {"id":"u-alice","name":"Alice Johnson","email":"alice@example.com","avatarColor":"#e8384f","role":"MEMBER",
   "isActive":true,"createdAt":"2026-10-15T08:00:00Z",
   "currentWorkspace":\##(workspace),
   "workspaces":[{"id":"ws-2","name":"Acme Pilot","isOrganization":false,"domain":null,"color":"#f06a6a","myRole":"GUEST",
                  "memberCount":3,"createdAt":"2026-10-18T10:00:00.123Z"},\##(workspace)]}
  """##

  static let meWithoutWorkspace = ##"""
  {"id":"u-alice","name":"Alice Johnson","email":"alice@example.com","avatarColor":"#e8384f","role":"MEMBER",
   "isActive":true,"createdAt":"2026-10-15T08:00:00Z","currentWorkspace":null,"workspaces":[]}
  """##

  static let task = ##"""
  {"id":"t-1","workspaceId":"ws-1","projectId":"p-1","sectionId":"s-1","parentId":null,"title":"Fix login redirect",
   "description":null,"assignee":\##(alice),"creator":\##(bob),"dueDate":"2026-10-20","startDate":null,
   "priority":"HIGH","completed":false,"completedAt":null,"position":1500.5,"subtaskCount":2,"completedSubtaskCount":1,
   "commentCount":3,"project":{"id":"p-1","name":"Mobile App v2","color":"#e0257f"},
   "createdAt":"2026-10-18T09:00:00.000Z","updatedAt":"2026-10-18T09:30:00Z"}
  """##

  static let taskDetail = ##"""
  {"id":"t-1","workspaceId":"ws-1","projectId":"p-1","sectionId":"s-1","parentId":null,"title":"Fix login redirect",
   "description":"**Steps**","assignee":null,"creator":\##(bob),"dueDate":null,"startDate":"2026-10-01",
   "priority":"NONE","completed":true,"completedAt":"2026-10-18T10:00:00.5Z","position":1000,"subtaskCount":1,
   "completedSubtaskCount":0,"commentCount":0,"project":null,
   "createdAt":"2026-10-18T09:00:00.000Z","updatedAt":"2026-10-18T09:30:00Z",
   "followers":[\##(alice),\##(bob)],"subtasks":[\##(task)],"parent":{"id":"t-0","title":"Epic"}}
  """##

  static let projectDetail = ##"""
  {"id":"p-1","workspaceId":"ws-1","teamId":"team-1","name":"Mobile App v2","description":null,"color":"#e0257f",
   "privacy":"TEAM","archived":false,"defaultView":"CALENDAR","owner":\##(bob),"myRole":null,
   "createdAt":"2026-10-18T09:00:00.000Z","updatedAt":"2026-10-18T09:00:00.000Z",
   "sections":[{"id":"s-1","projectId":"p-1","name":"To do","position":1000}],
   "members":[{"user":\##(bob),"role":"OWNER"}],"team":{"id":"team-1","name":"Engineering"}}
  """##

  static let stories = ##"""
  {"data":[
   {"kind":"activity","id":"a-1","actor":\##(bob),"type":"CREATED","data":null,"createdAt":"2026-10-18T09:00:00.000Z"},
   {"kind":"activity","id":"a-2","actor":\##(bob),"type":"ASSIGNED","data":{"assigneeId":"u-alice"},"createdAt":"2026-10-18T09:01:00Z"},
   {"kind":"activity","id":"a-3","actor":\##(bob),"type":"SOMETHING_NEW","data":{"n":1,"ok":true,"list":[1,"x"]},"createdAt":"2026-10-18T09:02:00Z"},
   {"kind":"comment","id":"c-1","author":\##(alice),"body":"Hey @[Bob Smith](u-bob), look","createdAt":"2026-10-18T09:03:00Z","editedAt":null}
  ]}
  """##

  static let notifications = ##"""
  {"data":[{"id":"n-1","workspaceId":"ws-1","type":"COMMENTED","read":false,"createdAt":"2026-10-18T09:03:00Z",
            "actor":\##(bob),"task":{"id":"t-1","title":"Fix login redirect","projectId":"p-1"}},
           {"id":"n-2","workspaceId":"ws-1","type":"GOAL_DUE","read":true,"createdAt":"2026-10-18T09:00:00Z",
            "actor":\##(bob),"task":null}],
   "unreadCount":1}
  """##

  static let users = ##"""
  {"data":[{"id":"u-alice","name":"Alice Johnson","email":"alice@example.com","avatarColor":"#e8384f","role":"ADMIN"},
           {"id":"u-guest","name":"Gita Guest","email":"guest@partner.test","avatarColor":"#aa62e3","role":"GUEST"}]}
  """##
}
