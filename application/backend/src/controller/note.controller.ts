import { Request, Response } from "express";
import { NoteService } from "../services/note.service";
import {Note} from "../entities/Note"
const noteService = new NoteService();
interface NoteParams {
    name: string;
}
export class NoteController {
    async getAll(_req: Request, res: Response) {
        try {
            const notes = await noteService.getAllNotes();
            res.json(notes);
        } catch (error) {
            res.status(500).json({ error: "Internal server error while fetching notes." });
        }
    }

    async getByName(req: Request<NoteParams>, res: Response) {
        try {
            const { name } = req.params;
            const note:Note | null = await noteService.getNoteByName(name);
            if (!note) return res.status(404).json({ error: "Note not found." });
            return res.json(note);
        } catch (error) {
           return res.status(500).json({ error: "Internal server error while fetching the note." });
        }
    }

    async create(req: Request, res: Response) {
        try {
            const { name, content } = req.body;
            if (!name || !content) {
                return res.status(400).json({ error: "Missing required fields: 'name' and 'content'." });
            }
            const note = await noteService.createNote(name, content);
            return res.status(201).json(note);
        } catch (error: any) {
            if (typeof error?.message === "string" && error.message.includes("already exists")) {
                return res.status(409).json({ error: error.message });
            }
            return res.status(500).json({ error: "Internal server error while creating the note." });
        }
    }

    async update(req: Request<NoteParams>, res: Response) {
        try {
            const { name } = req.params; 
            const { content } = req.body; 

            if (!content) return res.status(400).json({ error: "Missing required field: 'content'." });

            const updated = await noteService.updateNote(name, content);
            if (!updated) return res.status(404).json({ error: "Note not found." });

            return res.json(updated);
        } catch (error) {
            return res.status(500).json({ error: "Internal server error while updating the note." });
        }
    }

    async delete(req: Request<NoteParams>, res: Response) {
        try {
            const { name } = req.params; 
            const success = await noteService.deleteNote(name);
            if (!success) return res.status(404).json({ error: "Note not found." });
            
            return res.json({ message: "Note deleted successfully." });
        } catch (error) {
            return res.status(500).json({ error: "Internal server error while deleting the note." });
        }
    }
}